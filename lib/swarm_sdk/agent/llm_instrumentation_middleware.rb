# frozen_string_literal: true

module SwarmSDK
  module Agent
    # Faraday middleware for capturing LLM API requests and responses
    #
    # This middleware intercepts HTTP calls to LLM providers and emits
    # structured events via LogStream for logging and monitoring.
    #
    # Events emitted:
    # - llm_api_request: Before sending request to LLM API
    # - llm_api_response: After receiving response from LLM API
    #
    # The middleware is injected at runtime into the provider's Faraday
    # connection stack (see Agent::Chat#inject_llm_instrumentation).
    class LLMInstrumentationMiddleware < Faraday::Middleware
      # Initialize middleware
      #
      # @param app [Faraday::Connection] Faraday app
      # @param on_request [Proc] Callback for request events
      # @param on_response [Proc] Callback for response events
      # @param provider_name [String] Provider name for logging
      def initialize(app, on_request:, on_response:, provider_name:)
        super(app)
        @on_request = on_request
        @on_response = on_response
        @provider_name = provider_name
      end

      # Intercept HTTP call
      #
      # @param env [Faraday::Env] Request environment
      # @return [Faraday::Response] HTTP response
      def call(env)
        start_time = Time.now
        accumulated_raw_chunks = []

        # Emit request event
        emit_request_event(env, start_time)

        # Wrap existing on_data to capture raw SSE chunks for streaming
        if env.request&.on_data
          original_on_data = env.request.on_data
          env.request.on_data = proc do |chunk, bytes, response_env|
            # Capture raw chunk BEFORE RubyLLM processes it
            accumulated_raw_chunks << chunk
            # Call original handler (RubyLLM's stream processing)
            original_on_data.call(chunk, bytes, response_env)
          end
        end

        # Execute request
        @app.call(env).on_complete do |response_env|
          end_time = Time.now

          # Determine if this was a streaming request based on whether chunks were accumulated
          # This is more reliable than parsing response content
          is_streaming = accumulated_raw_chunks.any?

          # For streaming: use accumulated raw SSE chunks
          # For non-streaming: use response body
          raw_body = is_streaming ? accumulated_raw_chunks.join : response_env.body

          # Store SSE body in Fiber-local for citation extraction
          # This allows append_citations_to_content to access the full SSE body
          # even though response.body is empty for streaming responses
          Fiber[:last_sse_body] = raw_body if is_streaming

          # Emit response event
          timing = { start_time: start_time, end_time: end_time, duration: end_time - start_time }
          emit_response_event(response_env, timing, raw_body, is_streaming)
        end
      end

      private

      # Emit request event
      #
      # @param env [Faraday::Env] Request environment
      # @param timestamp [Time] Request timestamp
      # @return [void]
      def emit_request_event(env, timestamp)
        request_data = {
          provider: @provider_name,
          url: env.url.to_s,
          body: parse_body(env.body),
          timestamp: timestamp.utc.iso8601,
        }

        @on_request.call(request_data)
      rescue StandardError => e
        # Don't let logging errors break the request
        LogStream.emit_error(e, source: "llm_instrumentation_middleware", context: "emit_request_event", provider: @provider_name)
        RubyLLM.logger.debug("LLM instrumentation request error: #{e.message}")
      end

      # Emit response event
      #
      # @param env [Faraday::Env] Response environment
      # @param timing [Hash] Timing information with :start_time, :end_time, :duration keys
      # @param raw_body [String, nil] Raw response body (SSE stream for streaming, JSON for non-streaming)
      # @param streaming [Boolean] Whether this was a streaming response (determined by chunk accumulation)
      # @return [void]
      def emit_response_event(env, timing, raw_body, streaming)
        response_data = {
          provider: @provider_name,
          body: parse_body(raw_body),
          streaming: streaming,
          duration_seconds: timing[:duration].round(3),
          timestamp: timing[:end_time].utc.iso8601,
          status: env.status,
        }

        # Extract usage information from response body if available
        if raw_body.is_a?(String) && !raw_body.empty?
          begin
            if streaming
              # For streaming, parse the LAST SSE event which contains usage
              # Skip "[DONE]" marker and find the last actual data event
              last_data_line = raw_body.split("\n").reverse.find { |l| l.start_with?("data:") && !l.include?("[DONE]") }
              if last_data_line
                parsed = JSON.parse(last_data_line.sub(/^data:\s*/, ""))
                response_data[:usage] = extract_usage(parsed) if parsed.is_a?(Hash)
                response_data[:model] = parsed["model"] if parsed.is_a?(Hash)
              end
            else
              # For non-streaming, parse the full JSON response
              parsed = JSON.parse(raw_body)
              response_data[:usage] = extract_usage(parsed) if parsed.is_a?(Hash)
              response_data[:model] = parsed["model"] if parsed.is_a?(Hash)
              response_data[:finish_reason] = extract_finish_reason(parsed) if parsed.is_a?(Hash)
            end
          rescue JSON::ParserError
            # Not JSON, skip usage extraction
          end
        end

        @on_response.call(response_data)
      rescue StandardError => e
        # Don't let logging errors break the response
        LogStream.emit_error(e, source: "llm_instrumentation_middleware", context: "emit_response_event", provider: @provider_name)
        RubyLLM.logger.debug("LLM instrumentation response error: #{e.message}")
      end

      # Sanitize headers by removing sensitive data
      #
      # @param headers [Hash] HTTP headers
      # @return [Hash] Sanitized headers
      def sanitize_headers(headers)
        return {} unless headers

        headers.transform_keys(&:to_s).transform_values do |value|
          # Redact authorization headers
          if value.to_s.match?(/bearer|token|key/i)
            "[REDACTED]"
          else
            value.to_s
          end
        end
      rescue StandardError
        {}
      end

      # Parse request/response body
      #
      # For requests: returns parsed JSON hash
      # For responses: returns full body (JSON parsed or raw string for SSE)
      #
      # @param body [String, Hash, nil] HTTP body
      # @return [Hash, String, nil] Parsed body
      def parse_body(body)
        return if body.nil? || body == ""

        # Already parsed
        return body if body.is_a?(Hash)

        # Try to parse JSON
        JSON.parse(body)
      rescue JSON::ParserError
        # Return full body for SSE/non-JSON responses
        # Don't truncate - let consumers decide how to handle large bodies
        body.to_s
      rescue StandardError
        nil
      end

      # Extract usage statistics from response
      #
      # Handles different provider formats (OpenAI, Anthropic, etc.)
      #
      # @param parsed [Hash] Parsed response body
      # @return [Hash, nil] Usage statistics
      def extract_usage(parsed)
        usage = parsed["usage"] || parsed.dig("usage")
        return unless usage

        {
          input_tokens: usage["input_tokens"] || usage["prompt_tokens"],
          output_tokens: usage["output_tokens"] || usage["completion_tokens"],
          total_tokens: usage["total_tokens"],
        }.compact
      rescue StandardError
        nil
      end

      # Extract finish reason from response
      #
      # Handles different provider formats
      #
      # @param parsed [Hash] Parsed response body
      # @return [String, nil] Finish reason
      def extract_finish_reason(parsed)
        # Anthropic format
        return parsed["stop_reason"] if parsed["stop_reason"]

        # OpenAI format
        choices = parsed["choices"]
        return unless choices&.is_a?(Array) && !choices.empty?

        choices.first["finish_reason"]
      rescue StandardError
        nil
      end
    end
  end
end
