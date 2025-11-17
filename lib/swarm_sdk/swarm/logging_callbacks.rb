# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Logging callbacks for swarm events
    #
    # Extracted from Swarm to reduce class size and eliminate repetitive callback patterns.
    # These callbacks emit structured log events to LogStream for monitoring and debugging.
    module LoggingCallbacks
      # Register default logging callbacks for all swarm events
      #
      # Sets up low-priority callbacks that emit structured events to LogStream.
      # These callbacks only fire when LogStream.emitter is set (logging enabled).
      def register_default_logging_callbacks
        register_swarm_lifecycle_callbacks
        register_agent_lifecycle_callbacks
        register_tool_execution_callbacks
        register_context_warning_callback
      end

      # Setup logging infrastructure for an execution
      #
      # @param logs [Array] Log collection array
      # @yield [entry] Block called for each log entry
      def setup_logging(logs)
        # Force fresh subscription array for this execution
        Fiber[:log_subscriptions] = []

        # Subscribe to collect logs and forward to user's block
        LogCollector.subscribe do |entry|
          logs << entry
          yield(entry) if block_given?
        end

        # Set LogStream to use LogCollector as emitter
        LogStream.emitter = LogCollector
      end

      # Emit agent_start events if agents were initialized before logging was set up
      #
      # When agents are initialized BEFORE logging (e.g., via restore()),
      # we need to retroactively set up logging callbacks and emit agent_start events.
      def emit_retroactive_agent_start_events
        return if !@agents_initialized || @agent_start_events_emitted

        # Setup logging callbacks for all agents (they were skipped during initialization)
        setup_logging_for_all_agents

        # Emit agent_start events now that logging is ready
        emit_agent_start_events
        @agent_start_events_emitted = true
      end

      # Setup logging callbacks for all initialized agents
      #
      # Called after restore() when logging is enabled. Sets up logging callbacks
      # for each agent so that subsequent events are captured.
      def setup_logging_for_all_agents
        # Setup for PRIMARY agents
        @agents.each_value do |chat|
          chat.setup_logging if chat.respond_to?(:setup_logging)
        end

        # Setup for DELEGATION instances
        @delegation_instances.each_value do |chat|
          chat.setup_logging if chat.respond_to?(:setup_logging)
        end
      end

      # Emit agent_start events for all initialized agents
      #
      # Called retroactively when agents were initialized before logging was enabled.
      # Emits agent_start events so log stream captures complete agent lifecycle.
      def emit_agent_start_events
        return unless LogStream.emitter

        # Emit for PRIMARY agents
        @agents.each do |agent_name, chat|
          emit_agent_start_for(agent_name, chat, is_delegation: false)
        end

        # Emit for DELEGATION instances
        @delegation_instances.each do |instance_name, chat|
          base_name = extract_base_name(instance_name)
          emit_agent_start_for(instance_name.to_sym, chat, is_delegation: true, base_name: base_name)
        end

        # Mark as emitted to prevent duplicate emissions
        @agent_start_events_emitted = true
      end

      # Emit a single agent_start event
      #
      # @param agent_name [Symbol] Agent name (or instance name for delegations)
      # @param chat [Agent::Chat] Agent chat instance
      # @param is_delegation [Boolean] Whether this is a delegation instance
      # @param base_name [String, nil] Base agent name for delegations
      def emit_agent_start_for(agent_name, chat, is_delegation:, base_name: nil)
        base_name ||= agent_name
        agent_def = @agent_definitions[base_name]

        # Build plugin storage info using base name
        plugin_storage_info = {}
        @plugin_storages.each do |plugin_name, agent_storages|
          next unless agent_storages.key?(base_name)

          plugin_storage_info[plugin_name] = {
            enabled: true,
            config: agent_def.respond_to?(plugin_name) ? extract_plugin_config_info(agent_def.public_send(plugin_name)) : nil,
          }
        end

        LogStream.emit(
          type: "agent_start",
          agent: agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          swarm_name: @name,
          model: agent_def.model,
          provider: agent_def.provider || "openai",
          directory: agent_def.directory,
          system_prompt: agent_def.system_prompt,
          tools: chat.tool_names,
          delegates_to: agent_def.delegates_to,
          plugin_storages: plugin_storage_info,
          is_delegation_instance: is_delegation,
          base_agent: (base_name if is_delegation),
          timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        )
      end

      private

      # Register swarm lifecycle callbacks (swarm_start, swarm_stop)
      def register_swarm_lifecycle_callbacks
        add_default_callback(:swarm_start, priority: -100) do |context|
          emit_swarm_start_event(context)
        end

        add_default_callback(:swarm_stop, priority: -100) do |context|
          emit_swarm_stop_event(context)
        end
      end

      # Register agent lifecycle callbacks (user_prompt, agent_step, agent_stop)
      def register_agent_lifecycle_callbacks
        add_default_callback(:user_prompt, priority: -100) do |context|
          emit_user_prompt_event(context)
        end

        add_default_callback(:agent_step, priority: -100) do |context|
          emit_agent_step_event(context)
        end

        add_default_callback(:agent_stop, priority: -100) do |context|
          emit_agent_stop_event(context)
        end
      end

      # Register tool execution callbacks (pre_tool_use, post_tool_use)
      def register_tool_execution_callbacks
        add_default_callback(:pre_tool_use, priority: -100) do |context|
          emit_tool_call_event(context)
        end

        add_default_callback(:post_tool_use, priority: -100) do |context|
          emit_tool_result_event(context)
        end
      end

      # Register context warning callback
      def register_context_warning_callback
        add_default_callback(:context_warning, priority: -100) do |context|
          emit_context_warning_event(context)
        end
      end

      # Emit swarm_start event
      def emit_swarm_start_event(context)
        return unless LogStream.emitter

        LogStream.emit(
          type: "swarm_start",
          agent: context.metadata[:lead_agent],
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          swarm_name: context.metadata[:swarm_name],
          lead_agent: context.metadata[:lead_agent],
          prompt: context.metadata[:prompt],
          timestamp: context.metadata[:timestamp],
        )
      end

      # Emit swarm_stop event
      def emit_swarm_stop_event(context)
        return unless LogStream.emitter

        LogStream.emit(
          type: "swarm_stop",
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          swarm_name: context.metadata[:swarm_name],
          lead_agent: context.metadata[:lead_agent],
          last_agent: context.metadata[:last_agent],
          content: context.metadata[:content],
          success: context.metadata[:success],
          duration: context.metadata[:duration],
          total_cost: context.metadata[:total_cost],
          total_tokens: context.metadata[:total_tokens],
          agents_involved: context.metadata[:agents_involved],
          timestamp: context.metadata[:timestamp],
        )
      end

      # Emit user_prompt event
      def emit_user_prompt_event(context)
        return unless LogStream.emitter

        LogStream.emit(
          type: "user_prompt",
          agent: context.agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          model: context.metadata[:model] || "unknown",
          provider: context.metadata[:provider] || "unknown",
          message_count: context.metadata[:message_count] || 0,
          tools: context.metadata[:tools] || [],
          delegates_to: context.metadata[:delegates_to] || [],
          source: context.metadata[:source] || "user",
          metadata: context.metadata,
        )
      end

      # Emit agent_step event (intermediate response with tool calls)
      def emit_agent_step_event(context)
        return unless LogStream.emitter

        metadata_without_duplicates = context.metadata.except(
          :model, :content, :tool_calls, :finish_reason, :usage, :tool_executions
        )

        LogStream.emit(
          type: "agent_step",
          agent: context.agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          model: context.metadata[:model],
          content: context.metadata[:content],
          tool_calls: context.metadata[:tool_calls],
          finish_reason: context.metadata[:finish_reason],
          usage: context.metadata[:usage],
          tool_executions: context.metadata[:tool_executions],
          metadata: metadata_without_duplicates,
        )
      end

      # Emit agent_stop event (final response)
      def emit_agent_stop_event(context)
        return unless LogStream.emitter

        metadata_without_duplicates = context.metadata.except(
          :model, :content, :tool_calls, :finish_reason, :usage, :tool_executions
        )

        LogStream.emit(
          type: "agent_stop",
          agent: context.agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          model: context.metadata[:model],
          content: context.metadata[:content],
          tool_calls: context.metadata[:tool_calls],
          finish_reason: context.metadata[:finish_reason],
          usage: context.metadata[:usage],
          tool_executions: context.metadata[:tool_executions],
          metadata: metadata_without_duplicates,
        )
      end

      # Emit tool_call event (pre_tool_use)
      def emit_tool_call_event(context)
        return unless LogStream.emitter

        LogStream.emit(
          type: "tool_call",
          agent: context.agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          tool_call_id: context.tool_call.id,
          tool: context.tool_call.name,
          arguments: context.tool_call.parameters,
          metadata: context.metadata,
        )
      end

      # Emit tool_result event (post_tool_use)
      def emit_tool_result_event(context)
        return unless LogStream.emitter

        LogStream.emit(
          type: "tool_result",
          agent: context.agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          tool_call_id: context.tool_result.tool_call_id,
          tool: context.tool_result.tool_name,
          result: context.tool_result.content,
          metadata: context.metadata,
        )
      end

      # Emit context_limit_warning event
      def emit_context_warning_event(context)
        return unless LogStream.emitter

        LogStream.emit(
          type: "context_limit_warning",
          agent: context.agent_name,
          swarm_id: @swarm_id,
          parent_swarm_id: @parent_swarm_id,
          model: context.metadata[:model] || "unknown",
          threshold: "#{context.metadata[:threshold]}%",
          current_usage: "#{context.metadata[:percentage]}%",
          tokens_used: context.metadata[:tokens_used],
          tokens_remaining: context.metadata[:tokens_remaining],
          context_limit: context.metadata[:context_limit],
          metadata: context.metadata,
        )
      end

      # Extract base name from delegation instance name
      #
      # @param instance_name [String, Symbol] Instance name (e.g., "agent@1234")
      # @return [Symbol] Base agent name (e.g., :agent)
      def extract_base_name(instance_name)
        instance_name.to_s.split("@").first.to_sym
      end
    end
  end
end
