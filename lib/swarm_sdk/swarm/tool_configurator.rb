# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Handles tool creation, registration, and permissions wrapping
    #
    # Responsibilities:
    # - Register explicit tools for agents
    # - Register default tools (Read, Grep, Glob, etc.)
    # - Create tool instances (with agent context)
    # - Wrap tools with permissions validators
    #
    # This encapsulates all tool-related logic that was previously in Swarm.
    class ToolConfigurator
      # Default tools available to all agents (unless disable_default_tools is set)
      DEFAULT_TOOLS = [
        :Read,
        :Grep,
        :Glob,
      ].freeze

      # Scratchpad tools (added if scratchpad is enabled)
      SCRATCHPAD_TOOLS = [
        :ScratchpadWrite,
        :ScratchpadRead,
        :ScratchpadList,
      ].freeze

      # Filesystem tools that can be globally disabled for security
      FILESYSTEM_TOOLS = [
        :Read,
        :Write,
        :Edit,
        :MultiEdit,
        :Grep,
        :Glob,
        :Bash,
      ].freeze

      def initialize(swarm, scratchpad_storage, plugin_storages = {})
        @swarm = swarm
        @scratchpad_storage = scratchpad_storage
        # Plugin storages: { plugin_name => { agent_name => storage } }
        # e.g., { memory: { agent1: storage1, agent2: storage2 } }
        @plugin_storages = plugin_storages
      end

      # Register all tools for an agent (both explicit and default)
      #
      # @param chat [AgentChat] The chat instance to register tools with
      # @param agent_name [Symbol] Name of the agent
      # @param agent_definition [AgentDefinition] Agent definition object
      def register_all_tools(chat:, agent_name:, agent_definition:)
        register_explicit_tools(chat, agent_definition.tools, agent_name: agent_name, agent_definition: agent_definition)
        register_default_tools(chat, agent_name: agent_name, agent_definition: agent_definition)
      end

      # Create a tool instance by name
      #
      # Uses the Registry factory pattern to instantiate tools based on their
      # declared requirements. This eliminates the need for a giant case statement.
      #
      # File tools and TodoWrite require agent context for tracking state.
      # Scratchpad tools require shared scratchpad instance.
      # Plugin tools are delegated to their respective plugins.
      #
      # This method is public for testing delegation from Swarm.
      #
      # @param tool_name [Symbol, String] Tool name
      # @param agent_name [Symbol] Agent name for context
      # @param directory [String] Agent's working directory
      # @param chat [Agent::Chat, nil] Optional chat instance for tools that need it
      # @param agent_definition [Agent::Definition, nil] Optional agent definition
      # @return [RubyLLM::Tool] Tool instance
      def create_tool_instance(tool_name, agent_name, directory, chat: nil, agent_definition: nil)
        tool_name_sym = tool_name.to_sym

        # Check if tool is provided by a plugin
        if PluginRegistry.plugin_tool?(tool_name_sym)
          return create_plugin_tool(tool_name_sym, agent_name, directory, chat, agent_definition)
        end

        # Use Registry factory pattern - tools declare their own requirements
        context = {
          agent_name: agent_name,
          directory: directory,
          scratchpad_storage: @scratchpad_storage,
        }

        Tools::Registry.create(tool_name_sym, context)
      end

      # Wrap a tool instance with permissions validator if configured
      #
      # This method is public for testing delegation from Swarm.
      #
      # @param tool_instance [RubyLLM::Tool] Tool instance to wrap
      # @param permissions_config [Hash, nil] Permission configuration
      # @param agent_definition [AgentDefinition] Agent definition
      # @return [RubyLLM::Tool] Either the wrapped tool or original tool
      def wrap_tool_with_permissions(tool_instance, permissions_config, agent_definition)
        # Skip wrapping if no permissions or agent bypasses permissions
        return tool_instance unless permissions_config
        return tool_instance if agent_definition.bypass_permissions

        # Create permissions config and wrap tool with validator
        permissions = Permissions::Config.new(
          permissions_config,
          base_directory: agent_definition.directory,
        )

        Permissions::Validator.new(tool_instance, permissions)
      end

      private

      # Register explicitly configured tools
      #
      # @param chat [AgentChat] The chat instance
      # @param tool_configs [Array<Hash>] Tool configurations with optional permissions
      # @param agent_name [Symbol] Agent name
      # @param agent_definition [AgentDefinition] Agent definition
      def register_explicit_tools(chat, tool_configs, agent_name:, agent_definition:)
        # Validate filesystem tools if globally disabled
        unless @swarm.allow_filesystem_tools
          # Extract tool names from hashes and convert to symbols for comparison
          forbidden = tool_configs.map { |tc| tc[:name].to_sym }.select { |name| FILESYSTEM_TOOLS.include?(name) }
          unless forbidden.empty?
            raise ConfigurationError,
              "Filesystem tools are globally disabled (SwarmSDK.settings.allow_filesystem_tools = false) " \
                "but agent '#{agent_name}' attempts to use: #{forbidden.join(", ")}.\n\n" \
                "This is a system-wide security setting that cannot be overridden by swarm configuration.\n" \
                "To use filesystem tools, set SwarmSDK.settings.allow_filesystem_tools = true before loading the swarm."
          end
        end

        tool_configs.each do |tool_config|
          tool_name = tool_config[:name]
          permissions_config = tool_config[:permissions]

          # Create tool instance
          tool_instance = create_tool_instance(tool_name, agent_name, agent_definition.directory)

          # Wrap with permissions and add to chat
          wrap_and_add_tool(chat, tool_instance, permissions_config, agent_definition)
        end
      end

      # Register default tools for agents (unless disabled)
      #
      # Note: Memory tools are registered separately and are NOT affected by
      # disable_default_tools, since they're configured via memory {} block.
      #
      # @param chat [AgentChat] The chat instance
      # @param agent_name [Symbol] Agent name
      # @param agent_definition [AgentDefinition] Agent definition
      def register_default_tools(chat, agent_name:, agent_definition:)
        # Get explicit tool names to avoid duplicates
        explicit_tool_names = agent_definition.tools.map { |t| t[:name] }.to_set

        # Register core default tools (unless disabled)
        if agent_definition.disable_default_tools != true
          DEFAULT_TOOLS.each do |tool_name|
            # Skip filesystem tools if globally disabled
            next if !@swarm.allow_filesystem_tools && FILESYSTEM_TOOLS.include?(tool_name)

            register_tool_if_not_disabled(chat, tool_name, explicit_tool_names, agent_name, agent_definition)
          end

          # Register scratchpad tools if enabled
          if @swarm.scratchpad_enabled?
            SCRATCHPAD_TOOLS.each do |tool_name|
              register_tool_if_not_disabled(chat, tool_name, explicit_tool_names, agent_name, agent_definition)
            end
          end
        end

        # Register plugin tools if plugin storage is enabled for this agent
        # Plugin tools ARE affected by disable_default_tools (allows fine-grained control)
        register_plugin_tools(chat, agent_name, agent_definition, explicit_tool_names)
      end

      # Register a tool if not already explicit or disabled
      def register_tool_if_not_disabled(chat, tool_name, explicit_tool_names, agent_name, agent_definition)
        # Skip if already registered explicitly
        return if explicit_tool_names.include?(tool_name)

        # Skip if tool is in the disable list
        return if tool_disabled?(tool_name, agent_definition.disable_default_tools)

        tool_instance = create_tool_instance(tool_name, agent_name, agent_definition.directory)
        permissions_config = resolve_default_permissions(tool_name, agent_definition)

        wrap_and_add_tool(chat, tool_instance, permissions_config, agent_definition)
      end

      # Wrap tool with permissions and add to chat
      #
      # This is the common pattern for registering tools:
      # 1. Wrap with permissions validator (if configured)
      # 2. Add to chat
      #
      # @param chat [Agent::Chat] The chat instance
      # @param tool_instance [RubyLLM::Tool] Tool instance
      # @param permissions_config [Hash, nil] Permissions configuration
      # @param agent_definition [Agent::Definition] Agent definition
      # @return [void]
      def wrap_and_add_tool(chat, tool_instance, permissions_config, agent_definition)
        tool_instance = wrap_tool_with_permissions(tool_instance, permissions_config, agent_definition)
        chat.add_tool(tool_instance)
      end

      # Resolve permissions for a default/plugin tool
      #
      # Looks up permissions in agent-specific config first, falls back to global defaults.
      #
      # @param tool_name [Symbol] Tool name
      # @param agent_definition [Agent::Definition] Agent definition
      # @return [Hash, nil] Permissions configuration or nil
      def resolve_default_permissions(tool_name, agent_definition)
        agent_definition.agent_permissions[tool_name] || agent_definition.default_permissions[tool_name]
      end

      # Create a tool instance via plugin
      #
      # @param tool_name [Symbol] Tool name
      # @param agent_name [Symbol] Agent name
      # @param directory [String] Working directory
      # @param chat [Agent::Chat, nil] Chat instance
      # @param agent_definition [Agent::Definition, nil] Agent definition
      # @return [RubyLLM::Tool] Tool instance
      def create_plugin_tool(tool_name, agent_name, directory, chat, agent_definition)
        plugin = PluginRegistry.plugin_for_tool(tool_name)
        raise ConfigurationError, "Tool #{tool_name} is not provided by any plugin" unless plugin

        # V7.0: Extract base name for storage lookup (handles delegation instances)
        # For primary agents: :tester → :tester (no change)
        # For delegation instances: "tester@frontend" → :tester (extracts base)
        base_name = agent_name.to_s.split("@").first.to_sym

        # Get plugin storage using BASE NAME (shared across instances)
        plugin_storages = @plugin_storages[plugin.name] || {}
        storage = plugin_storages[base_name] # ← Changed from agent_name to base_name

        # Build context for tool creation
        # Pass full agent_name for tool state tracking (TodoWrite, ReadTracker, etc.)
        context = {
          agent_name: agent_name, # Full instance name for tool's use
          directory: directory,
          storage: storage, # Shared storage by base name
          agent_definition: agent_definition,
          chat: chat,
          tool_configurator: self,
        }

        plugin.create_tool(tool_name, context)
      end

      # Register plugin-provided tools for an agent
      #
      # Asks all plugins if they have tools to register for this agent.
      #
      # @param chat [Agent::Chat] Chat instance
      # @param agent_name [Symbol] Agent name
      # @param agent_definition [Agent::Definition] Agent definition
      # @param explicit_tool_names [Set<Symbol>] Already-registered tool names
      def register_plugin_tools(chat, agent_name, agent_definition, explicit_tool_names)
        PluginRegistry.all.each do |plugin|
          # Check if plugin has storage enabled for this agent
          next unless plugin.storage_enabled?(agent_definition)

          # Register each tool provided by the plugin
          plugin.tools.each do |tool_name|
            # Skip if already registered explicitly
            next if explicit_tool_names.include?(tool_name)

            # Skip if tool is disabled via disable_default_tools
            next if tool_disabled?(tool_name, agent_definition.disable_default_tools)

            tool_instance = create_tool_instance(
              tool_name,
              agent_name,
              agent_definition.directory,
              chat: chat,
              agent_definition: agent_definition,
            )

            permissions_config = resolve_default_permissions(tool_name, agent_definition)

            wrap_and_add_tool(chat, tool_instance, permissions_config, agent_definition)
          end
        end
      end

      # Check if a tool should be disabled based on disable_default_tools config
      #
      # @param tool_name [Symbol] Tool name to check
      # @param disable_config [nil, Boolean, Symbol, Array<Symbol>] Disable configuration
      # @return [Boolean] True if tool should be disabled
      def tool_disabled?(tool_name, disable_config)
        return false if disable_config.nil?

        # Normalize tool_name to symbol for comparison
        tool_name_sym = tool_name.to_sym

        if disable_config == true
          # Disable all default tools
          true
        elsif disable_config.is_a?(Symbol)
          # Single tool name
          disable_config == tool_name_sym
        elsif disable_config.is_a?(String)
          # Single tool name as string (from YAML)
          disable_config.to_sym == tool_name_sym
        elsif disable_config.is_a?(Array)
          # Disable only tools in the array - normalize to symbols for comparison
          disable_config.map(&:to_sym).include?(tool_name_sym)
        else
          false
        end
      end

      # Register agent delegation tools
      #
      # Creates delegation tools that allow one agent to call another.
      #
      # @param chat [AgentChat] The chat instance
      # @param delegate_names [Array<Symbol>] Names of agents to delegate to
      # @param agent_name [Symbol] Name of the agent doing the delegating
      def register_delegation_tools(chat, delegate_names, agent_name:)
        return if delegate_names.empty?

        delegate_names.each do |delegate_name|
          delegate_name = delegate_name.to_sym

          unless @agents.key?(delegate_name)
            raise ConfigurationError, "Agent delegates to unknown agent '#{delegate_name}'"
          end

          # Create a tool that delegates to the specified agent
          delegate_agent = @agents[delegate_name]
          delegate_definition = @agent_definitions[delegate_name]

          tool = Tools::Delegate.new(
            delegate_name: delegate_name.to_s,
            delegate_description: delegate_definition.description,
            delegate_chat: delegate_agent,
            agent_name: agent_name,
            swarm: @swarm,
            delegating_chat: chat,
          )

          chat.add_tool(tool)
        end
      end
    end
  end
end
