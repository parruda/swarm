# frozen_string_literal: true

module SwarmSDK
  # Global registry for reusable agent definitions
  #
  # AgentRegistry allows declaring agents in separate files that can be
  # referenced by name in swarm definitions. This promotes code reuse and
  # separation of concerns - agent definitions can live in dedicated files
  # while swarm configurations compose them together.
  #
  # ## Usage
  #
  # Register agents globally (typically in separate files):
  #
  #   # agents/backend.rb
  #   SwarmSDK.agent :backend do
  #     model "claude-sonnet-4"
  #     description "Backend API developer"
  #     system_prompt "You build REST APIs"
  #     tools :Read, :Edit, :Bash
  #   end
  #
  # Reference registered agents in swarm definitions:
  #
  #   # swarm.rb
  #   SwarmSDK.build do
  #     name "Dev Team"
  #     lead :backend
  #
  #     agent :backend  # Pulls from registry
  #   end
  #
  # ## Override Support
  #
  # Registered agents can be extended with additional configuration:
  #
  #   SwarmSDK.build do
  #     name "Dev Team"
  #     lead :backend
  #
  #     agent :backend do
  #       # Registry config is applied first, then this block
  #       tools :CustomTool  # Adds to tools from registry
  #       delegates_to :database
  #     end
  #   end
  #
  # @note This registry is not thread-safe. In multi-threaded environments,
  #   register all agents before spawning threads, or synchronize access
  #   externally. For typical fiber-based async usage (the default in SwarmSDK),
  #   this is not a concern.
  #
  class AgentRegistry
    @agents = {}

    class << self
      # Register an agent definition block
      #
      # Stores a configuration block that will be executed when the agent
      # is referenced in a swarm definition. The block receives an
      # Agent::Builder context and can use all builder DSL methods.
      #
      # @param name [Symbol, String] Agent name (will be symbolized)
      # @yield Agent configuration block using Agent::Builder DSL
      # @return [void]
      # @raise [ArgumentError] If no block is provided
      # @raise [ArgumentError] If agent with same name is already registered
      #
      # @example Register a backend agent
      #   SwarmSDK::AgentRegistry.register(:backend) do
      #     model "claude-sonnet-4"
      #     description "Backend developer"
      #     tools :Read, :Edit, :Bash
      #   end
      #
      # @example Register with MCP servers
      #   SwarmSDK::AgentRegistry.register(:filesystem_agent) do
      #     model "gpt-4"
      #     description "File manager"
      #     mcp_server :fs, type: :stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]
      #   end
      def register(name, &block)
        raise ArgumentError, "Block required for agent registration" unless block_given?

        sym_name = name.to_sym
        if @agents.key?(sym_name)
          raise ArgumentError,
            "Agent '#{sym_name}' is already registered. " \
              "Use SwarmSDK.clear_agent_registry! to reset, or choose a different name."
        end

        @agents[sym_name] = block
      end

      # Retrieve a registered agent block
      #
      # @param name [Symbol, String] Agent name
      # @return [Proc, nil] The registration block or nil if not found
      #
      # @example
      #   block = SwarmSDK::AgentRegistry.get(:backend)
      #   builder.instance_eval(&block) if block
      def get(name)
        @agents[name.to_sym]
      end

      # Check if an agent is registered
      #
      # @param name [Symbol, String] Agent name
      # @return [Boolean] true if agent is registered
      #
      # @example
      #   if SwarmSDK::AgentRegistry.registered?(:backend)
      #     puts "Backend agent is available"
      #   end
      def registered?(name)
        @agents.key?(name.to_sym)
      end

      # List all registered agent names
      #
      # @return [Array<Symbol>] Names of all registered agents
      #
      # @example
      #   SwarmSDK::AgentRegistry.names
      #   # => [:backend, :frontend, :database]
      def names
        @agents.keys
      end

      # Clear all registrations
      #
      # Primarily useful for testing to ensure clean state between tests.
      #
      # @return [void]
      #
      # @example In test setup/teardown
      #   def teardown
      #     SwarmSDK::AgentRegistry.clear
      #   end
      def clear
        @agents.clear
      end
    end
  end
end
