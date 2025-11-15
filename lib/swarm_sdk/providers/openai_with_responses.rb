# frozen_string_literal: true

module SwarmSDK
  module Providers
    # Extended OpenAI provider with responses API support
    #
    # RubyLLM's OpenAI provider only supports v1/chat/completions.
    # This provider extends it to also support v1/responses for models
    # that require it (e.g., gpt-5-pro, o-series models).
    #
    # ## Usage
    #
    # Set via AgentChat when api_version is configured:
    #
    # @example Via SwarmSDK AgentChat (automatic)
    #   # In swarm.yml:
    #   agents:
    #     researcher:
    #       model: gpt-5-pro
    #       api_version: "v1/responses"  # Automatically uses this provider
    #
    # @example Direct instantiation
    #   provider = OpenAIWithResponses.new(config, use_responses_api: true)
    #   chat = RubyLLM::Chat.new(model: "gpt-5-pro", provider: provider)
    #
    # ## Features
    #
    # - **Stateful mode**: Uses `previous_response_id` with `store: true` for efficient multi-turn
    # - **Stateless fallback**: Automatically falls back to sending full history if server doesn't store responses
    # - **TTL tracking**: Expires response IDs after 5 minutes to prevent "not found" errors
    # - **Auto-recovery**: Detects repeated failures and disables `previous_response_id` entirely
    #
    class OpenAIWithResponses < RubyLLM::Providers::OpenAI
      attr_accessor :use_responses_api
      attr_writer :agent_name

      # Backward compatibility alias - use Defaults module for new code
      RESPONSE_ID_TTL = Defaults::Timeouts::RESPONSES_API_TTL_SECONDS

      # Initialize the provider
      #
      # @param config [RubyLLM::Configuration] Configuration object
      # @param use_responses_api [Boolean, nil] Force endpoint choice (nil = auto-detect)
      def initialize(config, use_responses_api: nil)
        super(config)
        @use_responses_api = use_responses_api
        @model_id = nil
        @last_response_id = nil # Track last response ID for conversation state
        @last_response_time = nil # Track when response ID was created
        @response_id_failures = 0 # Track consecutive failures with response IDs
        @disable_response_id = false # Disable previous_response_id if repeatedly failing
        @agent_name = nil # Agent name for logging context (set externally)
      end

      # Return the completion endpoint URL
      #
      # @return [String] Either 'responses' or 'chat/completions'
      def completion_url
        endpoint = determine_endpoint
        RubyLLM.logger.debug("SwarmSDK OpenAIWithResponses: Using endpoint '#{endpoint}' (use_responses_api=#{@use_responses_api}, model=#{@model_id})")
        endpoint
      end

      # Return the streaming endpoint URL
      #
      # @return [String] Same as completion_url
      def stream_url
        completion_url
      end

      # Override complete to capture model_id before making request
      #
      # This allows auto-detection to work by inspecting the model being used
      def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, &block)
        @model_id = model.id
        super
      rescue RubyLLM::BadRequestError => e
        # Handle "response not found" errors by starting a fresh conversation
        if e.message.include?("not found") && @last_response_id
          @response_id_failures += 1

          # After 2 failures, disable previous_response_id entirely
          if @response_id_failures >= 2
            RubyLLM.logger.debug("SwarmSDK: Response IDs repeatedly not found (#{@response_id_failures} failures). " \
              "The server may not support storing responses. Disabling previous_response_id for this session.")
            @disable_response_id = true
          else
            RubyLLM.logger.debug("SwarmSDK: Response ID '#{@last_response_id}' not found (failure ##{@response_id_failures}), starting fresh conversation")
          end

          @last_response_id = nil
          @last_response_time = nil
          retry
        else
          raise
        end
      rescue RubyLLM::Error => e
        # If error explicitly mentions responses API and we're not using it, retry with responses API
        if should_retry_with_responses_api?(e)
          RubyLLM.logger.warn("SwarmSDK: Retrying with responses API for model: #{@model_id}")
          @use_responses_api = true
          retry
        else
          raise
        end
      end

      # Override render_payload to transform request body for Responses API
      #
      # The Responses API uses 'input' instead of 'messages' parameter
      #
      # @param messages [Array<RubyLLM::Message>] Conversation messages
      # @param tools [Hash] Available tools
      # @param temperature [Float, nil] Sampling temperature
      # @param model [RubyLLM::Model] Model to use
      # @param stream [Boolean] Enable streaming
      # @param schema [Hash, nil] Response format schema
      # @return [Hash] Request payload
      def render_payload(messages, tools:, temperature:, model:, stream: false, schema: nil)
        if should_use_responses_api?
          render_responses_payload(messages, tools: tools, temperature: temperature, model: model, stream: stream, schema: schema)
        else
          # Use original OpenAI chat/completions format
          super
        end
      end

      # Override parse_completion_response to handle Responses API response format
      #
      # @param response [Faraday::Response] HTTP response
      # @return [RubyLLM::Message, nil] Parsed message or nil
      def parse_completion_response(response)
        # Guard against nil response body before delegating to parsers
        if response.body.nil?
          log_parse_error("nil", "Received nil response body from API", response.body)
          return
        end

        if should_use_responses_api?
          parse_responses_api_response(response)
        else
          super
        end
      rescue NoMethodError => e
        # Catch fetch/dig errors on nil and provide better context
        if e.message.include?("undefined method") && (e.message.include?("fetch") || e.message.include?("dig"))
          log_parse_error(e.class.name, e.message, response.body, e.backtrace)
          nil
        else
          raise
        end
      end

      private

      # Determine which endpoint to use based on configuration and model
      #
      # @return [String] 'responses' or 'chat/completions'
      def determine_endpoint
        if @use_responses_api.nil?
          # Auto-detect based on model name
          requires_responses_api? ? "responses" : "chat/completions"
        elsif @use_responses_api
          "responses"
        else
          "chat/completions"
        end
      end

      # Check if the current model requires the responses API
      #
      # Since we control this via api_version configuration, we don't auto-detect.
      # This method is only called when use_responses_api is nil (no explicit setting).
      #
      # @return [Boolean] false - default to chat/completions for auto-detect
      def requires_responses_api?
        # Default to chat/completions when not explicitly configured
        # Users should set api_version: "v1/responses" to use responses API
        false
      end

      # Check if we should use responses API for the current request
      #
      # @return [Boolean] true if responses API should be used
      def should_use_responses_api?
        if @use_responses_api.nil?
          # Auto-detect based on model
          requires_responses_api?
        else
          @use_responses_api
        end
      end

      # Build request body for Responses API
      #
      # The Responses API uses conversation state via previous_response_id.
      # For multi-turn conversations:
      # 1. First turn: Send input with user message
      # 2. Get response with tool calls in output
      # 3. Next turn: Send previous_response_id + input with function_call_output items
      #
      # @param messages [Array<RubyLLM::Message>] Conversation messages
      # @param tools [Hash] Available tools
      # @param temperature [Float, nil] Sampling temperature
      # @param model [RubyLLM::Model] Model to use
      # @param stream [Boolean] Enable streaming
      # @param schema [Hash, nil] Response format schema
      # @return [Hash] Request payload
      def render_responses_payload(messages, tools:, temperature:, model:, stream: false, schema: nil)
        payload = {
          model: model.id,
          stream: stream,
        }

        # Use previous_response_id for multi-turn conversations
        # Only use it if:
        # 1. Not disabled due to repeated failures
        # 2. We have a response ID and timestamp
        # 3. It hasn't expired (based on TTL)
        # 4. There are new messages to send
        use_previous_response = !@disable_response_id &&
          @last_response_id &&
          @last_response_time &&
          (Time.now - @last_response_time) < RESPONSE_ID_TTL &&
          has_new_messages?(messages)

        if use_previous_response
          RubyLLM.logger.debug("SwarmSDK: Multi-turn request with previous_response_id=#{@last_response_id}")
          payload[:previous_response_id] = @last_response_id
          # Only send NEW input (messages after the last response)
          new_input = format_new_input_messages(messages)
          payload[:input] = new_input
          RubyLLM.logger.debug("SwarmSDK: New input for multi-turn: #{JSON.pretty_generate(new_input)}")
        else
          if @last_response_id && @last_response_time && (Time.now - @last_response_time) >= RESPONSE_ID_TTL
            RubyLLM.logger.debug("SwarmSDK: Response ID expired (age: #{(Time.now - @last_response_time).round}s), starting new conversation chain")
          else
            RubyLLM.logger.debug("SwarmSDK: First turn request (no previous_response_id)")
          end
          # First turn or no conversation state or expired
          initial_input = format_input_messages(messages)
          payload[:input] = initial_input
          RubyLLM.logger.debug("SwarmSDK: Initial input: #{JSON.pretty_generate(initial_input)}")
        end

        payload[:temperature] = temperature unless temperature.nil?

        # CRITICAL: Explicitly set store: true to ensure responses are saved
        # Without this, previous_response_id will not work because the response won't be retrievable
        payload[:store] = true

        # Use flat tool format for Responses API
        payload[:tools] = tools.map { |_, tool| responses_tool_for(tool) } if tools.any?

        if schema
          strict = schema[:strict] != false
          payload[:response_format] = {
            type: "json_schema",
            json_schema: {
              name: "response",
              schema: schema,
              strict: strict,
            },
          }
        end

        payload[:stream_options] = { include_usage: true } if stream
        payload
      end

      # Check if there are new messages since the last response
      #
      # @param messages [Array<RubyLLM::Message>] All conversation messages
      # @return [Boolean] True if there are new messages (tool results or user messages)
      def has_new_messages?(messages)
        return false if messages.empty?

        # Check if the last few messages include tool results (role: :tool)
        # This indicates we need to send them with previous_response_id
        messages.last(5).any? { |msg| msg.role == :tool }
      end

      # Format only NEW messages for Responses API (used with previous_response_id)
      #
      # When using previous_response_id, only send new input that wasn't in the previous request.
      # This typically includes:
      # - Tool results (as function_call_output items)
      # - New user messages
      #
      # @param messages [Array<RubyLLM::Message>] All conversation messages
      # @return [Array<Hash>] Formatted input array with only new messages
      def format_new_input_messages(messages)
        formatted = []

        # Find messages after the last assistant response
        # Typically this will be tool results and potentially new user input
        last_assistant_idx = messages.rindex { |msg| msg.role == :assistant }

        if last_assistant_idx
          new_messages = messages[(last_assistant_idx + 1)..-1]

          new_messages.each do |msg|
            case msg.role
            when :tool
              # Tool results become function_call_output items
              formatted << {
                type: "function_call_output",
                call_id: msg.tool_call_id,
                output: msg.content.to_s,
              }
            when :user
              # New user messages
              formatted << {
                role: "user",
                content: Media.format_content(msg.content),
              }
            when :system
              # New system messages (rare but possible)
              formatted << {
                role: "developer",
                content: Media.format_content(msg.content),
              }
            end
          end
        end

        formatted
      end

      # Format messages for Responses API input (first turn)
      #
      # For the first request in a conversation, include all user/system/assistant messages.
      # Tool calls and tool results are excluded as they're part of the conversation state.
      #
      # @param messages [Array<RubyLLM::Message>] Conversation messages
      # @return [Array<Hash>] Formatted input array
      def format_input_messages(messages)
        formatted = []

        messages.each do |msg|
          case msg.role
          when :user
            formatted << {
              role: "user",
              content: Media.format_content(msg.content),
            }
          when :system
            formatted << {
              role: "developer", # Responses API uses 'developer' instead of 'system'
              content: Media.format_content(msg.content),
            }
          when :assistant
            # Assistant messages - only include if they have text content (not just tool calls)
            unless msg.content.nil? || msg.content.empty?
              formatted << {
                role: "assistant",
                content: Media.format_content(msg.content),
              }
            end
            # NOTE: Tool calls are NOT included in input - they're part of the output/conversation state
          when :tool
            # Tool result messages should NOT be in the first request
            # They're only sent with previous_response_id
            nil
          end
        end

        formatted
      end

      # Convert tool to Responses API format (flat structure)
      #
      # Responses API uses a flat format with type at top level:
      # { type: "function", name: "tool_name", description: "...", parameters: {...} }
      #
      # This differs from chat/completions which nests under 'function':
      # { type: "function", function: { name: "tool_name", ... } }
      #
      # RubyLLM 1.9.0+: Uses tool.params_schema for unified schema generation.
      # This supports both old param helper and new params DSL, and includes
      # proper JSON Schema formatting (strict, additionalProperties, etc.)
      #
      # @param tool [RubyLLM::Tool] Tool to convert
      # @return [Hash] Tool definition in Responses API format
      def responses_tool_for(tool)
        # Use tool.params_schema which returns a complete JSON Schema hash
        # This works with both param helper and params DSL
        parameters_schema = tool.params_schema || empty_parameters_schema

        {
          type: "function",
          name: tool.name,
          description: tool.description,
          parameters: parameters_schema,
        }
      end

      # Empty parameter schema for tools with no parameters
      #
      # @return [Hash] Empty JSON Schema matching OpenAI's format
      def empty_parameters_schema
        {
          "type" => "object",
          "properties" => {},
          "required" => [],
          "additionalProperties" => false,
          "strict" => true,
        }
      end

      # Parse Responses API response
      #
      # The Responses API may have a different response structure than chat/completions.
      # This method tries multiple possible paths to find the message data.
      # IMPORTANT: Also captures the response ID for multi-turn conversations.
      #
      # @param response [Faraday::Response] HTTP response
      # @return [RubyLLM::Message, nil] Parsed message or nil
      def parse_responses_api_response(response)
        data = response.body

        # Handle nil or non-hash response body
        unless data.is_a?(Hash)
          log_parse_error("TypeError", "Expected response body to be Hash, got #{data.class}", data)
          return
        end

        # Debug logging to see actual response structure
        RubyLLM.logger.debug("SwarmSDK Responses API response: #{JSON.pretty_generate(data)}")

        return if data.empty?

        raise RubyLLM::Error.new(response, data.dig("error", "message")) if data.dig("error", "message")

        # Capture response ID and timestamp for conversation state (if not disabled)
        unless @disable_response_id
          @last_response_id = data["id"]
          @last_response_time = Time.now
          @response_id_failures = 0 # Reset failure counter on success
          RubyLLM.logger.debug("SwarmSDK captured response_id: #{@last_response_id} at #{@last_response_time}")
        end

        # Try different possible paths for the message data
        message_data = extract_message_data(data)

        RubyLLM.logger.debug("SwarmSDK extracted message_data: #{message_data.inspect} (class: #{message_data.class})")

        return unless message_data

        # Ensure message_data is a hash
        unless message_data.is_a?(Hash)
          RubyLLM.logger.error("SwarmSDK expected message_data to be Hash, got #{message_data.class}")
          return
        end

        RubyLLM::Message.new(
          role: :assistant,
          content: message_data["content"] || "", # Provide empty string as fallback
          tool_calls: parse_tool_calls(message_data["tool_calls"]),
          input_tokens: extract_input_tokens(data),
          output_tokens: extract_output_tokens(data),
          model_id: data["model"],
          raw: response,
        )
      end

      # Extract message data from Responses API response
      #
      # The Responses API uses an 'output' array with different item types:
      # - reasoning: Model's internal reasoning
      # - function_call: Tool call to execute
      # - message: Text response
      #
      # @param data [Hash] Response body
      # @return [Hash] Message data synthesized from output array
      def extract_message_data(data)
        output = data["output"]

        # If no output array, try fallback paths
        unless output.is_a?(Array)
          return data.dig("choices", 0, "message") || # Standard OpenAI format
              data.dig("response") ||                    # Another possible format
              data.dig("message")                        # Direct message format
        end

        # Parse the output array to extract content and tool calls
        content_parts = []
        tool_calls = []

        output.each do |item|
          case item["type"]
          when "message"
            # Message contains a content array with typed items
            if item["content"].is_a?(Array)
              item["content"].each do |content_item|
                case content_item["type"]
                when "output_text"
                  content_parts << content_item["text"]
                when "text"
                  content_parts << content_item["text"]
                end
              end
            elsif item["content"].is_a?(String)
              content_parts << item["content"]
            elsif item["text"]
              content_parts << item["text"]
            end
          when "function_call"
            # Convert to RubyLLM tool call format
            tool_calls << {
              "id" => item["call_id"],
              "type" => "function",
              "function" => {
                "name" => item["name"],
                "arguments" => item["arguments"],
              },
            }
          when "reasoning"
            # Skip reasoning items (internal model thought process)
            nil
          end
        end

        # Synthesize a message data hash
        {
          "role" => "assistant",
          "content" => content_parts.join("\n"),
          "tool_calls" => tool_calls.empty? ? nil : tool_calls,
        }
      end

      # Extract input tokens from various possible locations
      #
      # @param data [Hash] Response body
      # @return [Integer] Input token count
      def extract_input_tokens(data)
        data.dig("usage", "prompt_tokens") ||
          data.dig("usage", "input_tokens") ||
          0
      end

      # Extract output tokens from various possible locations
      #
      # @param data [Hash] Response body
      # @return [Integer] Output token count
      def extract_output_tokens(data)
        data.dig("usage", "completion_tokens") ||
          data.dig("usage", "output_tokens") ||
          0
      end

      # Check if we should retry with responses API after an error
      #
      # @param error [RubyLLM::Error] The error that occurred
      # @return [Boolean] true if we should retry with responses API
      def should_retry_with_responses_api?(error)
        # Only retry if we haven't already tried responses API
        return false if @use_responses_api

        # Check if error message explicitly mentions responses API
        error.message.include?("v1/responses") ||
          error.message.include?("only supported in") && error.message.include?("responses")
      end

      # Log response parsing errors as JSON events through LogStream
      #
      # @param error_class [String] Error class name
      # @param error_message [String] Error message
      # @param response_body [Object] Response body that failed to parse
      def log_parse_error(error_class, error_message, response_body, error_backtrace = nil)
        if @agent_name
          # Emit structured JSON log through LogStream
          LogStream.emit(
            type: "response_parse_error",
            agent: @agent_name,
            error_class: error_class,
            error_message: error_message,
            error_backtrace: error_backtrace,
            response_body: response_body.inspect,
          )
        else
          # Fallback to RubyLLM logger if agent name not set
          RubyLLM.logger.error("SwarmSDK: #{error_class}: #{error_message}\nResponse: #{response_body.inspect}\nError backtrace: #{error_backtrace.join("\n")}")
        end
      end
    end
  end
end
