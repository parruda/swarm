# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Handles the complex 5-pass agent initialization process
    #
    # Responsibilities:
    # - Create all agent chat instances (pass 1)
    # - Register delegation tools (pass 2)
    # - Setup agent contexts (pass 3)
    # - Configure hook system (pass 4)
    # - Apply YAML hooks if present (pass 5)
    #
    # This encapsulates the complex initialization logic that was previously
    # embedded in Swarm#initialize_agents.
    class AgentInitializer
      # Initialize with swarm reference (all data accessible via swarm)
      #
      # @param swarm [Swarm] The parent swarm instance
      def initialize(swarm)
        @swarm = swarm
        @agents = {}
        @agent_contexts = {}
      end

      # Initialize all agents with their chat instances and tools
      #
      # This implements a 6-pass algorithm:
      # 1. Create all Agent::Chat instances
      # 2. Register delegation tools (agents can call each other)
      # 3. Setup agent contexts for tracking
      # 4. Configure hook system
      # 5. Apply YAML hooks (if loaded from YAML)
      # 6. Activate tools (Plan 025: populate @llm_chat.tools from registry after plugins)
      #
      # @return [Hash] agents hash { agent_name => Agent::Chat }
      def initialize_all
        pass_1_create_agents
        pass_2_register_delegation_tools
        pass_3_setup_contexts
        pass_4_configure_hooks
        pass_5_apply_yaml_hooks
        pass_6_activate_tools # Plan 025: Activate tools after all plugins registered

        @agents
      end

      # Provide access to agent contexts for Swarm
      attr_reader :agent_contexts

      # Initialize a single agent in isolation (for observer agents)
      #
      # Creates an isolated agent chat without delegation tools,
      # suitable for observer agents that don't need to delegate.
      # Reuses existing create_agent_chat infrastructure.
      #
      # @param agent_name [Symbol] Name of agent to initialize
      # @return [Agent::Chat] Isolated agent chat instance
      # @raise [ConfigurationError] If agent not found
      #
      # @example
      #   initializer = AgentInitializer.new(swarm)
      #   chat = initializer.initialize_isolated_agent(:profiler)
      #   chat.ask("Analyze this prompt")
      def initialize_isolated_agent(agent_name)
        agent_def = @swarm.agent_definitions[agent_name]
        raise ConfigurationError, "Agent '#{agent_name}' not found" unless agent_def

        # Ensure plugin storages are created (needed by ToolConfigurator)
        create_plugin_storages if @swarm.plugin_storages.empty?

        # Reuse existing create_agent_chat infrastructure
        tool_configurator = ToolConfigurator.new(
          @swarm,
          @swarm.scratchpad_storage,
          @swarm.plugin_storages,
        )

        # Create chat using same method as pass_1_create_agents
        # This gives us full tool setup, MCP servers, etc.
        create_agent_chat(agent_name, agent_def, tool_configurator)
      end

      # Create a tool that delegates work to another agent
      #
      # This method is public for testing delegation from Swarm.
      #
      # @param name [String] Delegate agent name
      # @param description [String] Delegate agent description
      # @param delegate_chat [Agent::Chat] The delegate's chat instance
      # @param agent_name [Symbol] Name of the delegating agent
      # @param delegating_chat [Agent::Chat, nil] The chat instance of the agent doing the delegating
      # @param custom_tool_name [String, nil] Optional custom tool name (overrides auto-generated name)
      # @param preserve_context [Boolean] Whether to preserve conversation context between delegations (default: true)
      # @return [Tools::Delegate] Delegation tool
      def create_delegation_tool(name:, description:, delegate_chat:, agent_name:, delegating_chat: nil, custom_tool_name: nil, preserve_context: true)
        Tools::Delegate.new(
          delegate_name: name,
          delegate_description: description,
          delegate_chat: delegate_chat,
          agent_name: agent_name,
          swarm: @swarm,
          delegating_chat: delegating_chat,
          custom_tool_name: custom_tool_name,
          preserve_context: preserve_context,
        )
      end

      private

      # Pass 1: Create primary agent chat instances
      #
      # Only creates agents that will actually be used as primaries:
      # - The lead agent
      # - Agents with shared_across_delegations: true (shared delegates)
      # - Agents not used as delegates (standalone agents)
      #
      # Agents that are ONLY delegates with shared_across_delegations: false
      # are NOT created here - they'll be created as delegation instances in pass 2a.
      #
      # Agent creation is parallelized using Async::Barrier for faster initialization.
      def pass_1_create_agents
        # Create plugin storages for agents
        create_plugin_storages

        tool_configurator = ToolConfigurator.new(@swarm, @swarm.scratchpad_storage, @swarm.plugin_storages)

        # Filter agents that need primary creation
        agents_to_create = @swarm.agent_definitions.reject do |name, agent_definition|
          should_skip_primary_creation?(name, agent_definition)
        end

        # Create agents in parallel using Async::Barrier
        results = create_agents_in_parallel(agents_to_create, tool_configurator)

        # Store results and notify plugins (sequential for safety)
        results.each do |name, chat, agent_definition|
          @agents[name] = chat
          notify_plugins_agent_initialized(name, chat, agent_definition, tool_configurator)
        end
      end

      # Create multiple agents in parallel using Async fibers
      #
      # @param agents_to_create [Hash] Hash of { name => agent_definition }
      # @param tool_configurator [ToolConfigurator] Shared tool configurator
      # @return [Array<Array>] Array of [name, chat, agent_definition] tuples
      def create_agents_in_parallel(agents_to_create, tool_configurator)
        return [] if agents_to_create.empty?

        results = []
        errors = []
        mutex = Mutex.new

        Sync do
          barrier = Async::Barrier.new

          agents_to_create.each do |name, agent_definition|
            barrier.async do
              chat = create_agent_chat(name, agent_definition, tool_configurator)
              mutex.synchronize { results << [name, chat, agent_definition] }
            rescue StandardError => e
              # Catch errors to avoid Async warning logs (which fail in tests with StringIO)
              mutex.synchronize { errors << [name, e] }
            end
          end

          barrier.wait
        end

        # Re-raise first error if any occurred
        unless errors.empty?
          # Emit events for all errors (not just the first)
          errors.each do |agent_name, err|
            LogStream.emit(
              type: "agent_initialization_error",
              agent: agent_name,
              error_class: err.class.name,
              error_message: err.message,
              timestamp: Time.now.utc.iso8601,
            )
          end

          # Re-raise first error with context
          name, error = errors.first
          raise error.class, "Agent '#{name}' initialization failed: #{error.message}", error.backtrace
        end

        results
      end

      # Pass 2: Wire delegation tools (lazy loading for isolated delegates)
      #
      # This pass wires delegation tools for primary agents:
      # - Shared delegates use the primary agent instance
      # - Isolated delegates use LazyDelegateChat (created on first use)
      #
      # Sub-pass 2a (eager creation) is REMOVED - delegation instances are now lazy.
      # Sub-pass 2c (nested delegation) is handled by LazyDelegateChat when initialized.
      def pass_2_register_delegation_tools
        tool_configurator = ToolConfigurator.new(@swarm, @swarm.scratchpad_storage, @swarm.plugin_storages)

        # Wire primary agents to delegates (shared primaries or lazy loaders)
        @swarm.agent_definitions.each do |delegator_name, delegator_def|
          delegator_chat = @agents[delegator_name]

          # Skip if delegator doesn't exist as primary (wasn't created in pass_1)
          next unless delegator_chat

          delegator_def.delegation_configs.each do |delegation_config|
            wire_delegation(
              delegator_name: delegator_name,
              delegator_chat: delegator_chat,
              delegation_config: delegation_config,
              tool_configurator: tool_configurator,
            )
          end
        end

        # NOTE: Nested delegation wiring is now handled by LazyDelegateChat#wire_delegation_tools
        # when the lazy delegate is first accessed.
      end

      # Wire a single delegation from one agent to a delegate
      #
      # For isolated delegates, creates a LazyDelegateChat wrapper instead of
      # eagerly creating the chat instance.
      #
      # @param delegator_name [Symbol, String] Name of the agent doing the delegating
      # @param delegator_chat [Agent::Chat] Chat instance of the delegator
      # @param delegation_config [Hash] Delegation configuration with :agent, :tool_name, and :preserve_context keys
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @return [void]
      def wire_delegation(delegator_name:, delegator_chat:, delegation_config:, tool_configurator:)
        delegate_name_sym = delegation_config[:agent]
        delegate_name_str = delegate_name_sym.to_s
        custom_tool_name = delegation_config[:tool_name]
        preserve_context = delegation_config.fetch(:preserve_context, true)

        # Check if target is a registered swarm
        if @swarm.swarm_registry&.registered?(delegate_name_str)
          wire_swarm_delegation(delegator_name, delegator_chat, delegate_name_str, custom_tool_name, preserve_context)
        elsif @swarm.agent_definitions.key?(delegate_name_sym)
          wire_agent_delegation(
            delegator_name: delegator_name,
            delegator_chat: delegator_chat,
            delegate_name_sym: delegate_name_sym,
            custom_tool_name: custom_tool_name,
            preserve_context: preserve_context,
          )
        else
          raise ConfigurationError,
            "Agent '#{delegator_name}' delegates to unknown target '#{delegate_name_str}' (not a local agent or registered swarm)"
        end
      end

      # Wire delegation to an external swarm
      #
      # @param delegator_name [Symbol, String] Name of the delegating agent
      # @param delegator_chat [Agent::Chat] Chat instance of the delegator
      # @param swarm_name [String] Name of the registered swarm
      # @param custom_tool_name [String, nil] Optional custom tool name
      # @param preserve_context [Boolean] Whether to preserve context between delegations
      # @return [void]
      def wire_swarm_delegation(delegator_name, delegator_chat, swarm_name, custom_tool_name, preserve_context)
        tool = create_delegation_tool(
          name: swarm_name,
          description: "External swarm: #{swarm_name}",
          delegate_chat: nil, # Swarm delegation - no direct chat
          agent_name: delegator_name,
          delegating_chat: delegator_chat,
          custom_tool_name: custom_tool_name,
          preserve_context: preserve_context,
        )

        # Register in tool registry (Plan 025)
        delegator_chat.tool_registry.register(
          tool,
          source: :delegation,
          metadata: { delegate_name: swarm_name, delegation_type: :swarm, preserve_context: preserve_context },
        )
      end

      # Wire delegation to a local agent
      #
      # For shared delegates, uses the primary agent instance.
      # For isolated delegates, creates a LazyDelegateChat wrapper that
      # defers creation until first use.
      #
      # @param delegator_name [Symbol, String] Name of the delegating agent
      # @param delegator_chat [Agent::Chat] Chat instance of the delegator
      # @param delegate_name_sym [Symbol] Name of the delegate agent
      # @param custom_tool_name [String, nil] Optional custom tool name
      # @param preserve_context [Boolean] Whether to preserve context between delegations
      # @return [void]
      def wire_agent_delegation(delegator_name:, delegator_chat:, delegate_name_sym:, custom_tool_name:, preserve_context:)
        delegate_definition = @swarm.agent_definitions[delegate_name_sym]

        # Determine which chat instance to use
        target_chat = if delegate_definition.shared_across_delegations
          # Shared mode: use primary agent (semaphore-protected)
          @agents[delegate_name_sym]
        else
          # Isolated mode: use lazy loader (created on first delegation)
          instance_name = "#{delegate_name_sym}@#{delegator_name}"

          LazyDelegateChat.new(
            instance_name: instance_name,
            base_name: delegate_name_sym,
            agent_definition: delegate_definition,
            swarm: @swarm,
          )
        end

        # Create delegation tool pointing to chosen instance (or lazy loader)
        tool = create_delegation_tool(
          name: delegate_name_sym.to_s,
          description: delegate_definition.description,
          delegate_chat: target_chat,
          agent_name: delegator_name,
          delegating_chat: delegator_chat,
          custom_tool_name: custom_tool_name,
          preserve_context: preserve_context,
        )

        # Register in tool registry (Plan 025)
        delegator_chat.tool_registry.register(
          tool,
          source: :delegation,
          metadata: {
            delegate_name: delegate_name_sym,
            delegation_mode: delegate_definition.shared_across_delegations ? :shared : :isolated,
            preserve_context: preserve_context,
          },
        )
      end

      # Pass 3: Setup agent contexts
      #
      # Create Agent::Context for each agent to track delegations and metadata.
      # This is needed regardless of whether logging is enabled.
      #
      # NOTE: Delegation instances are now lazy-loaded, so their contexts are
      # set up in LazyDelegateChat#setup_context when first accessed.
      def pass_3_setup_contexts
        # Setup contexts for PRIMARY agents only
        # (Delegation instances handle their own context setup via LazyDelegateChat)
        @agents.each do |agent_name, chat|
          setup_agent_context(agent_name, @swarm.agent_definitions[agent_name], chat, is_delegation: false)
        end
      end

      # Setup context for an agent (primary or delegation instance)
      def setup_agent_context(agent_name, agent_definition, chat, is_delegation: false)
        # Generate actual tool names (custom or auto-generated) for context tracking
        delegate_tool_names = agent_definition.delegation_configs.map do |delegation_config|
          # Use custom name if provided, otherwise auto-generate
          delegation_config[:tool_name] || Tools::Delegate.tool_name_for(delegation_config[:agent])
        end

        context = Agent::Context.new(
          name: agent_name,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          delegation_tools: delegate_tool_names,
          metadata: { is_delegation_instance: is_delegation },
        )

        # Store context (only for primaries)
        @agent_contexts[agent_name] = context unless is_delegation

        # Always set agent context on chat
        chat.setup_context(context) if chat.respond_to?(:setup_context)

        # Configure logging if enabled
        return unless LogStream.emitter

        chat.setup_logging if chat.respond_to?(:setup_logging)

        # Emit validation warnings (only for primaries, not each delegation instance)
        emit_validation_warnings(agent_name, agent_definition) unless is_delegation
      end

      # Emit validation warnings as log events
      #
      # This validates the agent definition and emits any warnings as log events
      # through LogStream (so formatters can handle them).
      #
      # @param agent_name [Symbol] Agent name
      # @param agent_definition [Agent::Definition] Agent definition to validate
      # @return [void]
      def emit_validation_warnings(agent_name, agent_definition)
        warnings = agent_definition.validate

        warnings.each do |warning|
          case warning[:type]
          when :model_not_found
            LogStream.emit(
              type: "model_lookup_warning",
              agent: agent_name,
              model: warning[:model],
              error_message: warning[:error_message],
              suggestions: warning[:suggestions],
              timestamp: Time.now.utc.iso8601,
            )
          end
        end
      end

      # Pass 4: Configure hook system
      #
      # Setup the callback system for each agent, integrating with RubyLLM callbacks.
      #
      # NOTE: Delegation instances are now lazy-loaded, so their hooks are
      # configured in LazyDelegateChat#configure_hooks when first accessed.
      def pass_4_configure_hooks
        # Configure hooks for PRIMARY agents only
        # (Delegation instances handle their own hook setup via LazyDelegateChat)
        @agents.each do |agent_name, chat|
          configure_hooks_for_agent(agent_name, chat)
        end
      end

      # Configure hooks for an agent (primary or delegation instance)
      def configure_hooks_for_agent(agent_name, chat)
        base_name = extract_base_name(agent_name)
        agent_definition = @swarm.agent_definitions[base_name]

        chat.setup_hooks(
          registry: @swarm.hook_registry,
          agent_definition: agent_definition,
          swarm: @swarm,
        ) if chat.respond_to?(:setup_hooks)
      end

      # Pass 5: Apply YAML hooks
      #
      # If the swarm was loaded from YAML with agent-specific hooks,
      # apply them now via HooksAdapter.
      #
      # NOTE: Delegation instances are now lazy-loaded, so their YAML hooks are
      # applied in LazyDelegateChat#apply_yaml_hooks when first accessed.
      def pass_5_apply_yaml_hooks
        return unless @swarm.config_for_hooks

        # Apply YAML hooks to PRIMARY agents only
        # (Delegation instances handle their own YAML hooks via LazyDelegateChat)
        @agents.each do |agent_name, chat|
          apply_yaml_hooks_for_agent(agent_name, chat)
        end
      end

      # Apply YAML hooks for an agent (primary or delegation instance)
      def apply_yaml_hooks_for_agent(agent_name, chat)
        base_name = extract_base_name(agent_name)
        agent_config = @swarm.config_for_hooks.agents[base_name]
        return unless agent_config

        # Configuration.agents now returns hashes, not Definitions
        hooks = agent_config.is_a?(Hash) ? agent_config[:hooks] : agent_config.hooks
        return unless hooks&.any?

        Hooks::Adapter.apply_agent_hooks(chat, agent_name, hooks, @swarm.name)
      end

      # Pass 6: Activate tools after all plugins have registered (Plan 025)
      #
      # This must be the LAST pass because:
      # - Plugins register tools in on_agent_initialized (e.g., LoadSkill from memory plugin)
      # - Tools must be activated AFTER all registration is complete
      # - This populates @llm_chat.tools from the registry
      #
      # NOTE: Delegation instances are now lazy-loaded, so their tools are
      # activated in LazyDelegateChat#initialize_chat when first accessed.
      #
      # @return [void]
      def pass_6_activate_tools
        # Activate tools for PRIMARY agents only
        # (Delegation instances handle their own tool activation via LazyDelegateChat)
        @agents.each_value(&:activate_tools_for_prompt)
      end

      # Create Agent::Chat instance with rate limiting
      #
      # @param agent_name [Symbol] Agent name
      # @param agent_definition [Agent::Definition] Agent definition object
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @return [Agent::Chat] Configured agent chat instance
      def create_agent_chat(agent_name, agent_definition, tool_configurator)
        chat = Agent::Chat.new(
          definition: agent_definition.to_h,
          agent_name: agent_name,
          global_semaphore: @swarm.global_semaphore,
        )

        # Set agent name on provider for logging (if provider supports it)
        chat.provider.agent_name = agent_name if chat.provider.respond_to?(:agent_name=)

        # Register tools using ToolConfigurator
        tool_configurator.register_all_tools(
          chat: chat,
          agent_name: agent_name,
          agent_definition: agent_definition,
        )

        # Register MCP servers using McpConfigurator
        if agent_definition.mcp_servers.any?
          mcp_configurator = McpConfigurator.new(@swarm)
          mcp_configurator.register_mcp_servers(chat, agent_definition.mcp_servers, agent_name: agent_name)
        end

        # Setup tool activation dependencies (Plan 025)
        chat.setup_tool_activation(
          tool_configurator: tool_configurator,
          agent_definition: agent_definition,
        )

        # NOTE: activate_tools_for_prompt is called in Pass 5 after all plugins
        # have registered their tools (e.g., LoadSkill from memory plugin)

        chat
      end

      # NOTE: create_agent_chat_for_delegation and register_delegation_tools were removed.
      # Delegation instances are now lazy-loaded via LazyDelegateChat.

      # Create plugin storages for all agents
      #
      # Iterates through all registered plugins and asks each to create
      # storage for agents that need it.
      #
      # @return [void]
      def create_plugin_storages
        PluginRegistry.all.each do |plugin|
          @swarm.agent_definitions.each do |agent_name, agent_definition|
            # Check if this plugin needs storage for this agent
            next unless plugin.memory_configured?(agent_definition)

            # Get plugin config for this agent
            config = get_plugin_config(agent_definition, plugin.name)
            next unless config

            # Parse config through plugin
            parsed_config = plugin.parse_config(config)

            # Create plugin storage
            storage = plugin.create_storage(agent_name: agent_name, config: parsed_config)

            # Store in plugin_storages: { plugin_name => { agent_name => storage } }
            @swarm.plugin_storages[plugin.name] ||= {}
            @swarm.plugin_storages[plugin.name][agent_name] = storage
          end
        end
      end

      # Get plugin-specific config from agent definition
      #
      # Uses the generic plugin_configs accessor to retrieve plugin-specific config.
      # E.g., memory plugin config is accessed via `agent_definition.plugin_config(:memory)`
      #
      # @param agent_definition [Agent::Definition] Agent definition
      # @param plugin_name [Symbol] Plugin name
      # @return [Object, nil] Plugin config or nil
      def get_plugin_config(agent_definition, plugin_name)
        # Use generic plugin config accessor
        agent_definition.plugin_config(plugin_name)
      end

      # Notify all plugins that an agent was initialized
      #
      # Plugins can register additional tools, mark tools immutable, etc.
      #
      # @param agent_name [Symbol] Agent name
      # @param chat [Agent::Chat] Chat instance
      # @param agent_definition [Agent::Definition] Agent definition
      # @param tool_configurator [ToolConfigurator] Tool configurator
      # @return [void]
      def notify_plugins_agent_initialized(agent_name, chat, agent_definition, tool_configurator)
        PluginRegistry.all.each do |plugin|
          # Get plugin storage for this agent (if any)
          plugin_storages = @swarm.plugin_storages[plugin.name] || {}
          storage = plugin_storages[agent_name]

          # Build context for plugin
          context = {
            storage: storage,
            agent_definition: agent_definition,
            tool_configurator: tool_configurator,
          }

          # Notify plugin
          plugin.on_agent_initialized(agent_name: agent_name, agent: chat, context: context)
        end
      end

      # Determine if we should skip creating a primary agent
      #
      # Skip if:
      # - NOT the lead agent, AND
      # - Has shared_across_delegations: false (isolated mode), AND
      # - Is only referenced as a delegate (not used standalone)
      #
      # @param name [Symbol] Agent name
      # @param agent_definition [Agent::Definition] Agent definition
      # @return [Boolean] True if should skip primary creation
      def should_skip_primary_creation?(name, agent_definition)
        # Always create lead agent
        return false if name == @swarm.lead_agent

        # If shared mode, create primary (delegates will use it)
        return false if agent_definition.shared_across_delegations

        # Skip if only used as a delegate
        only_referenced_as_delegate?(name)
      end

      # Check if an agent is only referenced as a delegate
      #
      # @param name [Symbol] Agent name
      # @return [Boolean] True if only referenced as delegate
      def only_referenced_as_delegate?(name)
        # Check if any agent delegates to this one
        referenced_as_delegate = @swarm.agent_definitions.any? do |_agent_name, definition|
          definition.delegates_to.include?(name)
        end

        # Skip if referenced as delegate (and not lead, already checked above)
        referenced_as_delegate
      end

      # Extract base agent name from instance name
      #
      # @param instance_name [Symbol, String] Instance name (may be delegation instance)
      # @return [Symbol] Base agent name
      def extract_base_name(instance_name)
        instance_name.to_s.split("@").first.to_sym
      end

      # Check if instance name is a delegation instance
      #
      # @param instance_name [Symbol, String] Instance name
      # @return [Boolean] True if delegation instance (contains '@')
      def delegation_instance?(instance_name)
        instance_name.to_s.include?("@")
      end
    end
  end
end
