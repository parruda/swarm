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
      # ## Boot Optimization (Plan 025)
      #
      # - If tools specified: Create stubs without tools/list RPC (fast boot, lazy schema)
      # - If tools omitted: Call tools/list to discover all tools (discovery mode)
      #
      # @param chat [AgentChat] The agent's chat instance
      # @param mcp_server_configs [Array<Hash>] MCP server configurations
      # @param agent_name [Symbol] Agent name for tracking clients
      #
      # @example Fast boot mode
      #   mcp_server :codebase, type: :stdio, command: "mcp-server", tools: [:search, :list]
      #   # Creates tool stubs instantly, no tools/list RPC
      #
      # @example Discovery mode
      #   mcp_server :codebase, type: :stdio, command: "mcp-server"
      #   # Calls tools/list to discover all available tools
      def register_mcp_servers(chat, mcp_server_configs, agent_name:)
        return if mcp_server_configs.nil? || mcp_server_configs.empty?

        # Ensure MCP logging is configured before creating clients
        Swarm.apply_mcp_logging_configuration

        mcp_server_configs.each do |server_config|
          tools_config = server_config[:tools]
          mode = tools_config.nil? ? :discovery : :optimized

          # Emit event before initialization
          emit_mcp_init_start(agent_name, server_config, mode)

          client = initialize_mcp_client(server_config)

          # Store client for cleanup
          @mcp_clients[agent_name] << client

          if tools_config.nil?
            # Discovery mode: Fetch all tools from server (calls tools/list)
            # client.tools returns RubyLLM::Tool instances (already wrapped by internal Coordinator)
            all_tools = client.tools
            tool_names = all_tools.map { |t| t.respond_to?(:name) ? t.name : t.to_s }

            all_tools.each do |tool|
              chat.tool_registry.register(
                tool,
                source: :mcp,
                metadata: { server_name: server_config[:name] },
              )
            end

            # Emit completion event for discovery mode
            emit_mcp_init_complete(agent_name, server_config, mode, all_tools.size, tool_names)
            RubyLLM.logger.debug("SwarmSDK: Discovered and registered #{all_tools.size} tools from MCP server '#{server_config[:name]}'")
          else
            # Optimized mode: Create tool stubs without tools/list RPC (Plan 025)
            # Use client directly (it has internal coordinator)
            tool_names = tools_config.map(&:to_s)

            tools_config.each do |tool_name|
              stub = Tools::McpToolStub.new(
                client: client,
                name: tool_name.to_s,
                server_name: server_config[:name],
              )
              chat.tool_registry.register(
                stub,
                source: :mcp,
                metadata: { server_name: server_config[:name] },
              )
            end

            # Emit completion event for optimized mode
            emit_mcp_init_complete(agent_name, server_config, mode, tools_config.size, tool_names)
            RubyLLM.logger.debug("SwarmSDK: Registered #{tools_config.size} tool stubs from MCP server '#{server_config[:name]}' (lazy schema)")
          end
        rescue StandardError => e
          RubyLLM.logger.error("SwarmSDK: Failed to initialize MCP server '#{server_config[:name]}' for agent #{agent_name}: #{e.class.name}: #{e.message}")
          RubyLLM.logger.error("SwarmSDK: Backtrace: #{e.backtrace.first(5).join("\n  ")}")
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

      # Emit MCP server initialization start event
      #
      # @param agent_name [Symbol] Agent name
      # @param server_config [Hash] MCP server configuration
      # @param mode [Symbol] Initialization mode (:discovery or :optimized)
      # @return [void]
      def emit_mcp_init_start(agent_name, server_config, mode)
        LogStream.emit(
          type: "mcp_server_init_start",
          agent: agent_name,
          server_name: server_config[:name],
          transport_type: server_config[:type],
          mode: mode,
        )
      end

      # Emit MCP server initialization complete event
      #
      # @param agent_name [Symbol] Agent name
      # @param server_config [Hash] MCP server configuration
      # @param mode [Symbol] Initialization mode (:discovery or :optimized)
      # @param tool_count [Integer] Number of tools registered
      # @param tool_names [Array<String>] Names of registered tools
      # @return [void]
      def emit_mcp_init_complete(agent_name, server_config, mode, tool_count, tool_names)
        LogStream.emit(
          type: "mcp_server_init_complete",
          agent: agent_name,
          server_name: server_config[:name],
          transport_type: server_config[:type],
          mode: mode,
          tool_count: tool_count,
          tools: tool_names,
        )
      end
    end
  end
end
