# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Handles MCP (Model Context Protocol) server configuration and client management
    #
    # Responsibilities:
    # - Register MCP servers for agents
    # - Initialize MCP clients (stdio, SSE, streamable transports)
    # - Build transport-specific configurations
    # - Track clients for cleanup
    #
    # This encapsulates all MCP-related logic that was previously in Swarm.
    class McpConfigurator
      def initialize(swarm)
        @swarm = swarm
        @mcp_clients = swarm.mcp_clients
      end

      # Register MCP servers for an agent
      #
      # Connects to MCP servers and registers their tools with the agent's chat instance.
      # Supports stdio, SSE, and HTTP (streamable) transports.
      #
      # @param chat [AgentChat] The agent's chat instance
      # @param mcp_server_configs [Array<Hash>] MCP server configurations
      # @param agent_name [Symbol] Agent name for tracking clients
      def register_mcp_servers(chat, mcp_server_configs, agent_name:)
        return if mcp_server_configs.nil? || mcp_server_configs.empty?

        # Ensure MCP logging is configured before creating clients
        Swarm.apply_mcp_logging_configuration

        mcp_server_configs.each do |server_config|
          client = initialize_mcp_client(server_config)

          # Store client for cleanup
          @mcp_clients[agent_name] << client

          # Fetch tools from MCP server and register with chat
          # Tools are already in RubyLLM::Tool format
          tools = client.tools
          tools.each { |tool| chat.add_tool(tool) }

          RubyLLM.logger.debug("SwarmSDK: Registered #{tools.size} tools from MCP server '#{server_config[:name]}' for agent #{agent_name}")
        rescue StandardError => e
          RubyLLM.logger.error("SwarmSDK: Failed to initialize MCP server '#{server_config[:name]}' for agent #{agent_name}: #{e.message}")
          raise ConfigurationError, "Failed to initialize MCP server '#{server_config[:name]}': #{e.message}"
        end
      end

      # Build transport-specific configuration for MCP client
      #
      # This method is public for testing delegation from Swarm.
      #
      # @param transport_type [Symbol] Transport type (:stdio, :sse, :streamable)
      # @param config [Hash] MCP server configuration
      # @return [Hash] Transport-specific configuration
      def build_transport_config(transport_type, config)
        case transport_type
        when :stdio
          build_stdio_config(config)
        when :sse
          build_sse_config(config)
        when :streamable
          build_streamable_config(config)
        else
          raise ArgumentError, "Unsupported transport type: #{transport_type}"
        end
      end

      private

      # Initialize an MCP client from configuration
      #
      # @param config [Hash] MCP server configuration
      # @return [RubyLLM::MCP::Client] Initialized MCP client
      def initialize_mcp_client(config)
        # Convert timeout from seconds to milliseconds
        timeout_seconds = config[:timeout] || 30
        timeout_ms = timeout_seconds * 1000

        # Determine transport type
        transport_type = determine_transport_type(config[:type])

        # Build transport-specific configuration
        client_config = build_transport_config(transport_type, config)

        # Create and start MCP client
        RubyLLM::MCP.client(
          name: config[:name],
          transport_type: transport_type,
          request_timeout: timeout_ms,
          config: client_config,
        )
      end

      # Determine transport type from configuration
      #
      # @param type [Symbol, String, nil] Transport type from config
      # @return [Symbol] Normalized transport type
      def determine_transport_type(type)
        case type&.to_sym
        when :stdio then :stdio
        when :sse then :sse
        when :http, :streamable then :streamable
        else
          raise ArgumentError, "Unknown MCP transport type: #{type}"
        end
      end

      # Build stdio transport configuration
      #
      # @param config [Hash] MCP server configuration
      # @return [Hash] Stdio configuration
      def build_stdio_config(config)
        {
          command: config[:command],
          args: config[:args] || [],
          env: Utils.stringify_keys(config[:env] || {}),
        }
      end

      # Build SSE transport configuration
      #
      # @param config [Hash] MCP server configuration
      # @return [Hash] SSE configuration
      def build_sse_config(config)
        {
          url: config[:url],
          headers: config[:headers] || {},
          version: config[:version]&.to_sym || :http2,
        }
      end

      # Build streamable (HTTP) transport configuration
      #
      # @param config [Hash] MCP server configuration
      # @return [Hash] Streamable configuration
      def build_streamable_config(config)
        streamable_config = {
          url: config[:url],
          headers: config[:headers] || {},
          version: config[:version]&.to_sym || :http2,
        }

        # Only include rate_limit if present
        streamable_config[:rate_limit] = config[:rate_limit] if config[:rate_limit]

        streamable_config
      end
    end
  end
end
