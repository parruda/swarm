# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Lazy loader for delegation agent chats
    #
    # Instead of creating delegation instances eagerly at swarm initialization,
    # this class defers creation until the first delegation call. This improves
    # initialization performance for swarms where not all agents are used.
    #
    # Thread-safe via Mutex - safe for concurrent access.
    #
    # @example
    #   lazy_chat = LazyDelegateChat.new(
    #     instance_name: "backend@frontend",
    #     base_name: :backend,
    #     agent_definition: backend_def,
    #     swarm: swarm
    #   )
    #
    #   # Later, when delegation is first called:
    #   chat = lazy_chat.chat  # Creates agent on first access
    #   chat.ask("Do something")
    class LazyDelegateChat
      attr_reader :instance_name, :base_name, :agent_definition

      # Initialize a lazy delegate chat wrapper
      #
      # @param instance_name [String] Unique instance name ("base@delegator")
      # @param base_name [Symbol] Base agent name (for definition lookup)
      # @param agent_definition [Agent::Definition] Agent definition
      # @param swarm [Swarm] Parent swarm reference
      def initialize(instance_name:, base_name:, agent_definition:, swarm:)
        @instance_name = instance_name
        @base_name = base_name
        @agent_definition = agent_definition
        @swarm = swarm
        @chat = nil
        @mutex = Mutex.new
        @initialized = false
      end

      # Get or create the agent chat instance
      #
      # On first call, creates the agent chat and runs initialization.
      # Subsequent calls return the cached instance.
      #
      # @return [Agent::Chat] The initialized chat instance
      def chat
        return @chat if @initialized

        @mutex.synchronize do
          return @chat if @initialized

          @chat = initialize_chat
          @initialized = true
          @chat
        end
      end

      # Check if the agent has been initialized
      #
      # @return [Boolean] True if chat has been created
      def initialized?
        @mutex.synchronize { @initialized }
      end

      private

      # Create and initialize the agent chat
      #
      # This mirrors the initialization done in AgentInitializer passes 1-6
      # but for a single lazy delegate.
      #
      # @return [Agent::Chat] Fully initialized chat instance
      def initialize_chat
        emit_lazy_init_start

        # Create tool configurator
        tool_configurator = ToolConfigurator.new(
          @swarm,
          @swarm.scratchpad_storage,
          @swarm.plugin_storages,
        )

        # Create the agent chat (mirrors AgentInitializer#create_agent_chat_for_delegation)
        chat = create_delegation_chat(tool_configurator)

        # Store in delegation_instances (so other code can find it)
        @swarm.delegation_instances[@instance_name] = chat

        # Wire delegation tools for this instance (nested delegation support)
        wire_delegation_tools(chat, tool_configurator)

        # Setup context
        setup_context(chat)

        # Configure hooks
        configure_hooks(chat)

        # Apply YAML hooks if present
        apply_yaml_hooks(chat)

        # Activate tools
        chat.activate_tools_for_prompt

        # Notify plugins
        notify_plugins(chat, tool_configurator)

        emit_lazy_init_complete

        chat
      end

      # Create the delegation chat instance
      #
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @return [Agent::Chat] Newly created chat instance
      def create_delegation_chat(tool_configurator)
        chat = Agent::Chat.new(
          definition: @agent_definition.to_h,
          agent_name: @instance_name.to_sym,
          global_semaphore: @swarm.global_semaphore,
        )

        # Set provider agent name for logging
        chat.provider.agent_name = @instance_name if chat.provider.respond_to?(:agent_name=)

        # Register all tools (built-in, permissions, etc.)
        tool_configurator.register_all_tools(
          chat: chat,
          agent_name: @instance_name.to_sym,
          agent_definition: @agent_definition,
        )

        # Register MCP servers if configured
        if @agent_definition.mcp_servers.any?
          mcp_configurator = McpConfigurator.new(@swarm)
          mcp_configurator.register_mcp_servers(
            chat,
            @agent_definition.mcp_servers,
            agent_name: @instance_name,
          )
        end

        # Setup tool activation dependencies
        chat.setup_tool_activation(
          tool_configurator: tool_configurator,
          agent_definition: @agent_definition,
        )

        chat
      end

      # Wire delegation tools for this instance (nested delegation support)
      #
      # If this agent delegates to other agents, create those tools.
      # The delegate targets may themselves be lazy.
      #
      # @param chat [Agent::Chat] The chat instance
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @return [void]
      def wire_delegation_tools(chat, tool_configurator)
        @agent_definition.delegation_configs.each do |delegation_config|
          delegate_name_sym = delegation_config[:agent]
          delegate_name_str = delegate_name_sym.to_s
          custom_tool_name = delegation_config[:tool_name]
          preserve_context = delegation_config.fetch(:preserve_context, true)

          # Check if target is a registered swarm
          if @swarm.swarm_registry&.registered?(delegate_name_str)
            wire_swarm_delegation(chat, delegate_name_str, custom_tool_name, preserve_context)
          elsif @swarm.agent_definitions.key?(delegate_name_sym)
            wire_agent_delegation(chat, delegate_name_sym, custom_tool_name, tool_configurator, preserve_context)
          else
            raise ConfigurationError,
              "Agent '#{@instance_name}' delegates to unknown target '#{delegate_name_str}'"
          end
        end
      end

      # Wire delegation to an external swarm
      #
      # @param chat [Agent::Chat] The delegating chat
      # @param swarm_name [String] Name of the registered swarm
      # @param custom_tool_name [String, nil] Optional custom tool name
      # @param preserve_context [Boolean] Whether to preserve context
      # @return [void]
      def wire_swarm_delegation(chat, swarm_name, custom_tool_name, preserve_context)
        tool = Tools::Delegate.new(
          delegate_name: swarm_name,
          delegate_description: "External swarm: #{swarm_name}",
          delegate_chat: nil,
          agent_name: @instance_name,
          swarm: @swarm,
          delegating_chat: chat,
          custom_tool_name: custom_tool_name,
          preserve_context: preserve_context,
        )

        chat.tool_registry.register(
          tool,
          source: :delegation,
          metadata: { delegate_name: swarm_name, delegation_type: :swarm, preserve_context: preserve_context },
        )
      end

      # Wire delegation to a local agent
      #
      # For lazy-loaded agents, creates a LazyDelegateChat wrapper.
      # For shared agents, uses the primary instance.
      #
      # @param chat [Agent::Chat] The delegating chat
      # @param delegate_name_sym [Symbol] Name of the delegate agent
      # @param custom_tool_name [String, nil] Optional custom tool name
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @param preserve_context [Boolean] Whether to preserve context
      # @return [void]
      def wire_agent_delegation(chat, delegate_name_sym, custom_tool_name, tool_configurator, preserve_context)
        delegate_definition = @swarm.agent_definitions[delegate_name_sym]

        # Determine which chat instance to use
        target_chat = if delegate_definition.shared_across_delegations
          # Shared mode: use primary agent
          @swarm.agents[delegate_name_sym]
        else
          # Isolated mode: create nested lazy loader or get existing instance
          nested_instance_name = "#{delegate_name_sym}@#{@instance_name}"

          # Check if already exists (might have been created by another path)
          existing = @swarm.delegation_instances[nested_instance_name]
          if existing
            existing
          else
            # Create lazy loader for nested delegation
            LazyDelegateChat.new(
              instance_name: nested_instance_name,
              base_name: delegate_name_sym,
              agent_definition: delegate_definition,
              swarm: @swarm,
            )
          end
        end

        # Create delegation tool pointing to chosen instance
        tool = Tools::Delegate.new(
          delegate_name: delegate_name_sym.to_s,
          delegate_description: delegate_definition.description,
          delegate_chat: target_chat,
          agent_name: @instance_name,
          swarm: @swarm,
          delegating_chat: chat,
          custom_tool_name: custom_tool_name,
          preserve_context: preserve_context,
        )

        chat.tool_registry.register(
          tool,
          source: :delegation,
          metadata: {
            delegate_name: delegate_name_sym,
            delegation_mode: delegate_definition.shared_across_delegations ? :shared : :isolated,
            preserve_context: preserve_context,
          },
        )
      end

      # Setup agent context
      #
      # @param chat [Agent::Chat] The chat instance
      # @return [void]
      def setup_context(chat)
        delegate_tool_names = @agent_definition.delegation_configs.map do |delegation_config|
          delegation_config[:tool_name] || Tools::Delegate.tool_name_for(delegation_config[:agent])
        end

        context = Agent::Context.new(
          name: @instance_name.to_sym,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          delegation_tools: delegate_tool_names,
          metadata: { is_delegation_instance: true },
        )

        chat.setup_context(context) if chat.respond_to?(:setup_context)

        # Configure logging if enabled
        return unless LogStream.emitter

        chat.setup_logging if chat.respond_to?(:setup_logging)
      end

      # Configure hooks for the agent
      #
      # @param chat [Agent::Chat] The chat instance
      # @return [void]
      def configure_hooks(chat)
        return unless chat.respond_to?(:setup_hooks)

        chat.setup_hooks(
          registry: @swarm.hook_registry,
          agent_definition: @agent_definition,
          swarm: @swarm,
        )
      end

      # Apply YAML hooks if present
      #
      # @param chat [Agent::Chat] The chat instance
      # @return [void]
      def apply_yaml_hooks(chat)
        return unless @swarm.config_for_hooks

        agent_config = @swarm.config_for_hooks.agents[@base_name]
        return unless agent_config

        hooks = agent_config.is_a?(Hash) ? agent_config[:hooks] : agent_config.hooks
        return unless hooks&.any?

        Hooks::Adapter.apply_agent_hooks(chat, @instance_name.to_sym, hooks, @swarm.name)
      end

      # Notify plugins that agent was initialized
      #
      # @param chat [Agent::Chat] The chat instance
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @return [void]
      def notify_plugins(chat, tool_configurator)
        PluginRegistry.all.each do |plugin|
          plugin_storages = @swarm.plugin_storages[plugin.name] || {}
          storage = plugin_storages[@base_name]

          context = {
            storage: storage,
            agent_definition: @agent_definition,
            tool_configurator: tool_configurator,
          }

          plugin.on_agent_initialized(
            agent_name: @instance_name.to_sym,
            agent: chat,
            context: context,
          )
        end
      end

      # Emit lazy initialization start event
      #
      # @return [void]
      def emit_lazy_init_start
        LogStream.emit(
          type: "agent_lazy_initialization_start",
          instance_name: @instance_name,
          base_name: @base_name,
          timestamp: Time.now.utc.iso8601,
        )
      end

      # Emit lazy initialization complete event
      #
      # @return [void]
      def emit_lazy_init_complete
        LogStream.emit(
          type: "agent_lazy_initialization_complete",
          instance_name: @instance_name,
          base_name: @base_name,
          timestamp: Time.now.utc.iso8601,
        )
      end
    end
  end
end
