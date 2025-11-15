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

        # Emit request event
        emit_request_event(env, start_time)

        # Execute request
        @app.call(env).on_complete do |response_env|
          end_time = Time.now
          duration = end_time - start_time

          # Emit response event
          emit_response_event(response_env, start_time, end_time, duration)
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
      # @param start_time [Time] Request start time
      # @param end_time [Time] Request end time
      # @param duration [Float] Request duration in seconds
      # @return [void]
      def emit_response_event(env, start_time, end_time, duration)
        response_data = {
          provider: @provider_name,
          body: parse_body(env.body),
          duration_seconds: duration.round(3),
          timestamp: end_time.utc.iso8601,
        }

        # Extract usage information from response body if available
        if env.body.is_a?(String) && !env.body.empty?
          begin
            parsed = JSON.parse(env.body)
            response_data[:usage] = extract_usage(parsed) if parsed.is_a?(Hash)
            response_data[:model] = parsed["model"] if parsed.is_a?(Hash)
            response_data[:finish_reason] = extract_finish_reason(parsed) if parsed.is_a?(Hash)
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
      # @param body [String, Hash, nil] HTTP body
      # @return [Hash, String, nil] Parsed body
      def parse_body(body)
        return if body.nil? || body == ""

        # Already parsed
        return body if body.is_a?(Hash)

        # Try to parse JSON
        JSON.parse(body)
      rescue JSON::ParserError
        # Return truncated string if not JSON
        body.to_s[0..1000]
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
