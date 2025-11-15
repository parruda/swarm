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
      # rubocop:disable Metrics/ParameterLists
      def initialize(swarm, agent_definitions, global_semaphore, hook_registry, scratchpad_storage, plugin_storages, config_for_hooks: nil)
        # rubocop:enable Metrics/ParameterLists
        @swarm = swarm
        @agent_definitions = agent_definitions
        @global_semaphore = global_semaphore
        @hook_registry = hook_registry
        @scratchpad_storage = scratchpad_storage
        @plugin_storages = plugin_storages
        @config_for_hooks = config_for_hooks
        @agents = {}
        @agent_contexts = {}
      end

      # Initialize all agents with their chat instances and tools
      #
      # This implements a 5-pass algorithm:
      # 1. Create all Agent::Chat instances
      # 2. Register delegation tools (agents can call each other)
      # 3. Setup agent contexts for tracking
      # 4. Configure hook system
      # 5. Apply YAML hooks (if loaded from YAML)
      #
      # @return [Hash] agents hash { agent_name => Agent::Chat }
      def initialize_all
        pass_1_create_agents
        pass_2_register_delegation_tools
        pass_3_setup_contexts
        pass_4_configure_hooks
        pass_5_apply_yaml_hooks

        @agents
      end

      # Provide access to agent contexts for Swarm
      attr_reader :agent_contexts

      # Create a tool that delegates work to another agent
      #
      # This method is public for testing delegation from Swarm.
      #
      # @param name [String] Delegate agent name
      # @param description [String] Delegate agent description
      # @param delegate_chat [Agent::Chat] The delegate's chat instance
      # @param agent_name [Symbol] Name of the delegating agent
      # @param delegating_chat [Agent::Chat, nil] The chat instance of the agent doing the delegating
      # @return [Tools::Delegate] Delegation tool
      def create_delegation_tool(name:, description:, delegate_chat:, agent_name:, delegating_chat: nil)
        Tools::Delegate.new(
          delegate_name: name,
          delegate_description: description,
          delegate_chat: delegate_chat,
          agent_name: agent_name,
          swarm: @swarm,
          hook_registry: @hook_registry,
          call_stack: @swarm.delegation_call_stack,
          swarm_registry: @swarm.swarm_registry,
          delegating_chat: delegating_chat,
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
      def pass_1_create_agents
        # Create plugin storages for agents
        create_plugin_storages

        tool_configurator = ToolConfigurator.new(@swarm, @scratchpad_storage, @plugin_storages)

        @agent_definitions.each do |name, agent_definition|
          # Skip if this agent will only exist as delegation instances
          next if should_skip_primary_creation?(name, agent_definition)

          chat = create_agent_chat(name, agent_definition, tool_configurator)
          @agents[name] = chat

          # Notify plugins that agent was initialized
          notify_plugins_agent_initialized(name, chat, agent_definition, tool_configurator)
        end
      end

      # Pass 2: Create delegation instances and wire delegation tools
      #
      # This pass has three sub-steps that must happen in order:
      # 2a. Create delegation instances (ONLY for agents with shared_across_delegations: false)
      # 2b. Wire primary agents to delegation instances OR shared primaries
      # 2c. Wire delegation instances to their delegates (nested delegation support)
      def pass_2_register_delegation_tools
        tool_configurator = ToolConfigurator.new(@swarm, @scratchpad_storage, @plugin_storages)

        # Sub-pass 2a: Create delegation instances for isolated agents
        @agent_definitions.each do |delegator_name, delegator_def|
          delegator_def.delegates_to.each do |delegate_base_name|
            delegate_base_name = delegate_base_name.to_sym

            unless @agent_definitions.key?(delegate_base_name)
              raise ConfigurationError,
                "Agent '#{delegator_name}' delegates to unknown agent '#{delegate_base_name}'"
            end

            delegate_definition = @agent_definitions[delegate_base_name]

            # Check isolation mode of the DELEGATE agent
            # If delegate wants to be shared, skip instance creation (use primary)
            next if delegate_definition.shared_across_delegations

            # Create unique delegation instance (isolated mode)
            instance_name = "#{delegate_base_name}@#{delegator_name}"

            # V7.0: Use existing register_all_tools (no new method needed!)
            delegation_chat = create_agent_chat_for_delegation(
              instance_name: instance_name,
              base_name: delegate_base_name,
              agent_definition: delegate_definition,
              tool_configurator: tool_configurator,
            )

            # Store in delegation_instances hash
            @swarm.delegation_instances[instance_name] = delegation_chat
          end
        end

        # Sub-pass 2b: Wire primary agents to delegation instances OR shared primaries OR registered swarms
        @agent_definitions.each do |delegator_name, delegator_def|
          delegator_chat = @agents[delegator_name]

          # Skip if delegator doesn't exist as primary (wasn't created in pass_1)
          next unless delegator_chat

          delegator_def.delegates_to.each do |delegate_base_name|
            delegate_base_name_str = delegate_base_name.to_s

            # Check if target is a registered swarm
            if @swarm.swarm_registry&.registered?(delegate_base_name_str)
              # Create delegation tool for swarm
              tool = create_delegation_tool(
                name: delegate_base_name_str,
                description: "External swarm: #{delegate_base_name_str}",
                delegate_chat: nil, # Swarm delegation - no direct chat
                agent_name: delegator_name,
                delegating_chat: delegator_chat,
              )

              delegator_chat.add_tool(tool)
            elsif @agent_definitions.key?(delegate_base_name)
              # Delegate to local agent
              delegate_definition = @agent_definitions[delegate_base_name]

              # Determine which chat instance to use
              target_chat = if delegate_definition.shared_across_delegations
                # Shared mode: use primary agent (old behavior)
                @agents[delegate_base_name]
              else
                # Isolated mode: use delegation instance
                instance_name = "#{delegate_base_name}@#{delegator_name}"
                @swarm.delegation_instances[instance_name]
              end

              # Create delegation tool pointing to chosen instance
              tool = create_delegation_tool(
                name: delegate_base_name.to_s,
                description: delegate_definition.description,
                delegate_chat: target_chat, # ← Isolated instance OR shared primary
                agent_name: delegator_name,
                delegating_chat: delegator_chat,
              )

              delegator_chat.add_tool(tool)
            else
              raise ConfigurationError, "Agent '#{delegator_name}' delegates to unknown target '#{delegate_base_name_str}' (not a local agent or registered swarm)"
            end
          end
        end

        # Sub-pass 2c: Wire delegation instances to their delegates (nested delegation)
        # Convert to array first to avoid "can't add key during iteration" error
        @swarm.delegation_instances.to_a.each do |instance_name, delegation_chat|
          base_name = extract_base_name(instance_name)
          delegate_definition = @agent_definitions[base_name]

          # Register delegation tools for THIS instance's delegates_to
          delegate_definition.delegates_to.each do |nested_delegate_name|
            nested_delegate_name_sym = nested_delegate_name.to_sym
            nested_delegate_name_str = nested_delegate_name.to_s

            # Check if target is a registered swarm
            if @swarm.swarm_registry&.registered?(nested_delegate_name_str)
              # Create delegation tool for swarm
              nested_tool = create_delegation_tool(
                name: nested_delegate_name_str,
                description: "External swarm: #{nested_delegate_name_str}",
                delegate_chat: nil, # Swarm delegation - no direct chat
                agent_name: instance_name.to_sym,
                delegating_chat: delegation_chat,
              )

              delegation_chat.add_tool(nested_tool)
            elsif @agent_definitions.key?(nested_delegate_name_sym)
              # Delegate to local agent
              nested_definition = @agent_definitions[nested_delegate_name_sym]

              # Determine target: shared primary OR isolated instance
              target_chat = if nested_definition.shared_across_delegations
                # Shared mode: point to primary (semaphore-protected)
                @agents[nested_delegate_name_sym]
              else
                # Isolated mode: delegation instances also get isolated nested delegates
                # Create unique instance for this delegation chain
                nested_instance_name = "#{nested_delegate_name}@#{instance_name}"

                # Check if already created in 2a (if delegator also delegates to this agent)
                @swarm.delegation_instances[nested_instance_name] ||= create_agent_chat_for_delegation(
                  instance_name: nested_instance_name,
                  base_name: nested_delegate_name_sym,
                  agent_definition: nested_definition,
                  tool_configurator: tool_configurator,
                )
              end

              # Create delegation tool
              nested_tool = create_delegation_tool(
                name: nested_delegate_name.to_s,
                description: nested_definition.description,
                delegate_chat: target_chat, # ← Isolated OR shared
                agent_name: instance_name.to_sym,
                delegating_chat: delegation_chat,
              )

              delegation_chat.add_tool(nested_tool)
            else
              raise ConfigurationError,
                "Delegation instance '#{instance_name}' delegates to unknown target '#{nested_delegate_name_str}' (not a local agent or registered swarm)"
            end
          end
        end
      end

      # Pass 3: Setup agent contexts
      #
      # Create Agent::Context for each agent to track delegations and metadata.
      # This is needed regardless of whether logging is enabled.
      def pass_3_setup_contexts
        # Setup contexts for PRIMARY agents
        @agents.each do |agent_name, chat|
          setup_agent_context(agent_name, @agent_definitions[agent_name], chat, is_delegation: false)
        end

        # Setup contexts for DELEGATION instances
        @swarm.delegation_instances.each do |instance_name, chat|
          base_name = extract_base_name(instance_name)
          agent_definition = @agent_definitions[base_name]
          setup_agent_context(instance_name.to_sym, agent_definition, chat, is_delegation: true)
        end
      end

      # Setup context for an agent (primary or delegation instance)
      def setup_agent_context(agent_name, agent_definition, chat, is_delegation: false)
        delegate_tool_names = agent_definition.delegates_to.map do |delegate_name|
          "#{Tools::Delegate::TOOL_NAME_PREFIX}#{delegate_name.to_s.capitalize}"
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
      def pass_4_configure_hooks
        # Configure hooks for PRIMARY agents
        @agents.each do |agent_name, chat|
          configure_hooks_for_agent(agent_name, chat)
        end

        # Configure hooks for DELEGATION instances
        @swarm.delegation_instances.each do |instance_name, chat|
          configure_hooks_for_agent(instance_name.to_sym, chat)
        end
      end

      # Configure hooks for an agent (primary or delegation instance)
      def configure_hooks_for_agent(agent_name, chat)
        base_name = extract_base_name(agent_name)
        agent_definition = @agent_definitions[base_name]

        chat.setup_hooks(
          registry: @hook_registry,
          agent_definition: agent_definition,
          swarm: @swarm,
        ) if chat.respond_to?(:setup_hooks)
      end

      # Pass 5: Apply YAML hooks
      #
      # If the swarm was loaded from YAML with agent-specific hooks,
      # apply them now via HooksAdapter.
      def pass_5_apply_yaml_hooks
        return unless @config_for_hooks

        # Apply YAML hooks to PRIMARY agents
        @agents.each do |agent_name, chat|
          apply_yaml_hooks_for_agent(agent_name, chat)
        end

        # Apply YAML hooks to DELEGATION instances
        @swarm.delegation_instances.each do |instance_name, chat|
          apply_yaml_hooks_for_agent(instance_name.to_sym, chat)
        end
      end

      # Apply YAML hooks for an agent (primary or delegation instance)
      def apply_yaml_hooks_for_agent(agent_name, chat)
        base_name = extract_base_name(agent_name)
        agent_config = @config_for_hooks.agents[base_name]
        return unless agent_config

        # Configuration.agents now returns hashes, not Definitions
        hooks = agent_config.is_a?(Hash) ? agent_config[:hooks] : agent_config.hooks
        return unless hooks&.any?

        Hooks::Adapter.apply_agent_hooks(chat, agent_name, hooks, @swarm.name)
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
          global_semaphore: @global_semaphore,
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

        chat
      end

      # Create a delegation-specific instance of an agent
      #
      # V7.0: Simplified - just calls register_all_tools with instance_name
      #
      # @param instance_name [String] Unique instance name ("base@delegator")
      # @param base_name [Symbol] Base agent name (for definition lookup)
      # @param agent_definition [Agent::Definition] Base agent definition
      # @param tool_configurator [ToolConfigurator] Shared tool configurator
      # @return [Agent::Chat] Delegation-specific chat instance
      def create_agent_chat_for_delegation(instance_name:, base_name:, agent_definition:, tool_configurator:)
        # Create chat with instance_name for isolated conversation + tool state
        chat = Agent::Chat.new(
          definition: agent_definition.to_h,
          agent_name: instance_name.to_sym, # Full instance name for isolation
          global_semaphore: @global_semaphore,
        )

        # Set provider agent name for logging
        chat.provider.agent_name = instance_name if chat.provider.respond_to?(:agent_name=)

        # V7.0 SIMPLIFIED: Just call register_all_tools with instance_name!
        # Base name extraction happens automatically in create_plugin_tool
        tool_configurator.register_all_tools(
          chat: chat,
          agent_name: instance_name.to_sym,
          agent_definition: agent_definition,
        )

        # Register MCP servers (tracked by instance_name automatically)
        if agent_definition.mcp_servers.any?
          mcp_configurator = McpConfigurator.new(@swarm)
          mcp_configurator.register_mcp_servers(
            chat,
            agent_definition.mcp_servers,
            agent_name: instance_name,
          )
        end

        # Notify plugins (use instance_name, plugins extract base_name if needed)
        notify_plugins_agent_initialized(instance_name.to_sym, chat, agent_definition, tool_configurator)

        chat
      end

      # Register agent delegation tools
      #
      # Creates delegation tools that allow one agent to call another.
      #
      # @param chat [Agent::Chat] The chat instance
      # @param delegate_names [Array<Symbol>] Names of agents to delegate to
      # @param agent_name [Symbol] Name of the agent doing the delegating
      def register_delegation_tools(chat, delegate_names, agent_name:)
        return if delegate_names.empty?

        delegate_names.each do |delegate_name|
          delegate_name_sym = delegate_name.to_sym
          delegate_name_str = delegate_name.to_s

          # Check if target is a local agent
          if @agents.key?(delegate_name_sym)
            # Delegate to local agent
            delegate_agent = @agents[delegate_name_sym]
            delegate_definition = @agent_definitions[delegate_name_sym]

            tool = create_delegation_tool(
              name: delegate_name_str,
              description: delegate_definition.description,
              delegate_chat: delegate_agent,
              agent_name: agent_name,
              delegating_chat: chat,
            )

            chat.add_tool(tool)
          elsif @swarm.swarm_registry&.registered?(delegate_name_str)
            # Delegate to registered swarm
            tool = create_delegation_tool(
              name: delegate_name_str,
              description: "External swarm: #{delegate_name_str}",
              delegate_chat: nil, # Swarm delegation - no direct chat
              agent_name: agent_name,
              delegating_chat: chat,
            )

            chat.add_tool(tool)
          else
            raise ConfigurationError, "Agent '#{agent_name}' delegates to unknown target '#{delegate_name_str}' (not a local agent or registered swarm)"
          end
        end
      end

      # Create plugin storages for all agents
      #
      # Iterates through all registered plugins and asks each to create
      # storage for agents that need it.
      #
      # @return [void]
      def create_plugin_storages
        PluginRegistry.all.each do |plugin|
          @agent_definitions.each do |agent_name, agent_definition|
            # Check if this plugin needs storage for this agent
            next unless plugin.storage_enabled?(agent_definition)

            # Get plugin config for this agent
            config = get_plugin_config(agent_definition, plugin.name)
            next unless config

            # Parse config through plugin
            parsed_config = plugin.parse_config(config)

            # Create plugin storage
            storage = plugin.create_storage(agent_name: agent_name, config: parsed_config)

            # Store in plugin_storages: { plugin_name => { agent_name => storage } }
            @plugin_storages[plugin.name] ||= {}
            @plugin_storages[plugin.name][agent_name] = storage
          end
        end
      end

      # Get plugin-specific config from agent definition
      #
      # Plugins can store their config in agent definition under their plugin name.
      # E.g., memory plugin looks for `agent_definition.memory`
      #
      # @param agent_definition [Agent::Definition] Agent definition
      # @param plugin_name [Symbol] Plugin name
      # @return [Object, nil] Plugin config or nil
      def get_plugin_config(agent_definition, plugin_name)
        # Try to call method named after plugin (e.g., .memory for :memory plugin)
        if agent_definition.respond_to?(plugin_name)
          agent_definition.public_send(plugin_name)
        end
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
          plugin_storages = @plugin_storages[plugin.name] || {}
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
        referenced_as_delegate = @agent_definitions.any? do |_agent_name, definition|
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
