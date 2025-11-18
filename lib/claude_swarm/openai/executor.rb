# frozen_string_literal: true

require "openai"
require "faraday/net_http_persistent"
require "faraday/retry"

module ClaudeSwarm
  module OpenAI
    class Executor < BaseExecutor
      # Static configuration for Faraday retry middleware
      FARADAY_RETRY_CONFIG = {
        max: 3, # Maximum number of retries
        interval: 0.5, # Initial delay between retries (in seconds)
        interval_randomness: 0.5, # Randomness factor for retry intervals
        backoff_factor: 2, # Exponential backoff factor
        exceptions: [
          Faraday::TimeoutError,
          Faraday::ConnectionFailed,
          Faraday::ServerError, # Retry on 5xx errors
        ].freeze,
        retry_statuses: [429, 500, 502, 503, 504].freeze, # HTTP status codes to retry
      }.freeze

      # Static configuration for OpenAI client
      OPENAI_CLIENT_CONFIG = {
        log_errors: true,
        request_timeout: 1800, # 30 minutes
      }.freeze

      def initialize(working_directory: Dir.pwd, model: nil, mcp_config: nil, vibe: false,
        instance_name: nil, instance_id: nil, calling_instance: nil, calling_instance_id: nil,
        claude_session_id: nil, additional_directories: [], debug: false,
        temperature: nil, api_version: "chat_completion", openai_token_env: "OPENAI_API_KEY",
        base_url: nil, reasoning_effort: nil, zdr: false)
        # Call parent initializer for common attributes
        super(
          working_directory: working_directory,
          model: model,
          mcp_config: mcp_config,
          vibe: vibe,
          instance_name: instance_name,
          instance_id: instance_id,
          calling_instance: calling_instance,
          calling_instance_id: calling_instance_id,
          claude_session_id: claude_session_id,
          additional_directories: additional_directories,
          debug: debug
        )

        # OpenAI-specific attributes
        @temperature = temperature
        @api_version = api_version
        @base_url = base_url
        @reasoning_effort = reasoning_effort
        @zdr = zdr

        # Conversation state for maintaining context
        @conversation_messages = []
        @previous_response_id = nil

        # Setup OpenAI client
        setup_openai_client(openai_token_env)

        # Setup MCP client for tools
        setup_mcp_client

        # Create API handler based on api_version
        @api_handler = create_api_handler
      end

      def execute(prompt, options = {})
        # Log the request
        log_request(prompt)

        # Start timing
        start_time = Time.now

        # Execute using the appropriate handler
        result = @api_handler.execute(prompt, options)

        # Calculate duration
        duration_ms = ((Time.now - start_time) * 1000).round

        # Build and return response
        build_response(result, duration_ms)
      rescue StandardError => e
        logger.error { "Unexpected error for #{@instance_name}: #{e.class} - #{e.message}" }
        logger.error { "Backtrace: #{e.backtrace.join("\n")}" }
        raise
      end

      def reset_session
        super
        @api_handler&.reset_session
      end

      # Session JSON logger for the API handlers
      def session_json_logger
        self
      end

      def log(event)
        append_to_session_json(event)
      end

      private

      def setup_openai_client(token_env)
        openai_client_config = build_openai_client_config(token_env)

        @openai_client = ::OpenAI::Client.new(openai_client_config) do |faraday|
          # Use persistent HTTP connections for better performance
          faraday.adapter(:net_http_persistent)

          # Add retry middleware with custom configuration
          faraday.request(:retry, **build_faraday_retry_config)
        end
      rescue KeyError
        raise ExecutionError, "OpenAI API key not found in environment variable: #{token_env}"
      end

      def setup_mcp_client
        return unless @mcp_config && File.exist?(@mcp_config)

        # Read MCP config to find MCP servers
        mcp_data = JsonHandler.parse_file!(@mcp_config)

        # Build MCP configurations from servers
        mcp_configs = build_mcp_configs(mcp_data["mcpServers"])
        return if mcp_configs.empty?

        # Create MCP client with unbundled environment to avoid bundler conflicts
        # This ensures MCP servers run in a clean environment without inheriting
        # Claude Swarm's BUNDLE_* environment variables
        Bundler.with_unbundled_env do
          @mcp_client = MCPClient.create_client(
            mcp_server_configs: mcp_configs,
            logger: @logger,
          )

          # List available tools from all MCP servers
          load_mcp_tools(mcp_configs)
        end
      rescue StandardError => e
        logger.error { "Failed to setup MCP client: #{e.message}" }
        @mcp_client = nil
        @available_tools = []
      end

      def calculate_cost(_result)
        # Simplified cost calculation
        # In reality, we'd need to track token usage
        "$0.00"
      end

      def create_api_handler
        handler_params = {
          openai_client: @openai_client,
          mcp_client: @mcp_client,
          available_tools: @available_tools,
          executor: self,
          instance_name: @instance_name,
          model: @model,
          temperature: @temperature,
          reasoning_effort: @reasoning_effort,
          zdr: @zdr,
        }

        if @api_version == "responses"
          OpenAI::Responses.new(**handler_params)
        else
          OpenAI::ChatCompletion.new(**handler_params)
        end
      end

      def log_streaming_content(content)
        # Log streaming content similar to ClaudeCodeExecutor
        logger.debug { "#{instance_info} streaming: #{content}" }
      end

      def build_faraday_retry_config
        FARADAY_RETRY_CONFIG.merge(
          retry_block: method(:handle_retry_logging),
        )
      end

      def handle_retry_logging(env:, options:, retry_count:, exception:, will_retry:)
        retry_delay = options.interval * (options.backoff_factor**(retry_count - 1))
        error_info = exception&.message || "HTTP #{env.status}"

        message = if will_retry
          "Request failed (attempt #{retry_count}/#{options.max}): #{error_info}. Retrying in #{retry_delay} seconds..."
        else
          "Request failed after #{retry_count} attempts: #{error_info}. Giving up."
        end

        @logger.warn(message)
      end

      def build_openai_client_config(token_env)
        OPENAI_CLIENT_CONFIG.merge(access_token: ENV.fetch(token_env)).tap do |config|
          config[:uri_base] = @base_url if @base_url
        end
      end

      def build_stdio_config(name, server_config)
        # Combine command and args into a single array
        command_array = [server_config["command"]]
        command_array.concat(server_config["args"] || [])

        MCPClient.stdio_config(
          command: command_array,
          name: name,
        ).tap do |config|
          config[:read_timeout] = 1800
        end
      end

      def build_mcp_configs(mcp_servers)
        return [] if mcp_servers.nil? || mcp_servers.empty?

        mcp_servers.filter_map do |name, server_config|
          case server_config["type"]
          when "stdio"
            build_stdio_config(name, server_config)
          when "sse"
            logger.warn { "SSE MCP servers not yet supported for OpenAI instances: #{name}" }
            # TODO: Add SSE support when available in ruby-mcp-client
            nil
          end
        end
      end

      def load_mcp_tools(mcp_configs)
        @available_tools = @mcp_client.list_tools
        logger.info { "Loaded #{@available_tools.size} tools from #{mcp_configs.size} MCP server(s)" }
      rescue StandardError => e
        logger.error { "Failed to load MCP tools: #{e.message}" }
        @available_tools = []
      end

      def build_response(result, duration_ms)
        {
          "type" => "result",
          "result" => result,
          "duration_ms" => duration_ms,
          "total_cost" => calculate_cost(result),
          "session_id" => @session_id,
        }.tap do |response|
          log_response(response)
          @last_response = response
        end
      end
    end
  end
end
