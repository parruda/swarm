# frozen_string_literal: true

module SwarmSDK
  # Restores swarm/workflow conversation state from snapshots
  #
  # Unified implementation that works for both Swarm and Workflow.
  # Validates compatibility between snapshot and current configuration,
  # restores conversation history, context state, scratchpad contents, and
  # read tracking information.
  #
  # Handles configuration mismatches gracefully by skipping agents that
  # don't exist in the current swarm/workflow and returning warnings in RestoreResult.
  #
  # ## System Prompt Handling
  #
  # By default, system prompts are taken from the **current YAML configuration**,
  # not from the snapshot. This makes configuration the source of truth and allows
  # you to update system prompts without creating new sessions.
  #
  # Set `preserve_system_prompts: true` to use historical prompts from the snapshot
  # (useful for debugging, auditing, or exact reproducibility).
  #
  # @example Restore with current system prompts (default)
  #   swarm = SwarmSDK.build { ... }
  #   snapshot_data = JSON.parse(File.read("session.json"), symbolize_names: true)
  #   result = swarm.restore(snapshot_data)
  #   # Uses system prompts from current YAML config
  #
  # @example Restore with historical system prompts
  #   result = swarm.restore(snapshot_data, preserve_system_prompts: true)
  #   # Uses system prompts that were active when snapshot was created
  class StateRestorer
    # Initialize state restorer
    #
    # @param orchestration [Swarm, Workflow] Swarm or workflow to restore into
    # @param snapshot [Snapshot, Hash, String] Snapshot object, hash, or JSON string
    # @param preserve_system_prompts [Boolean] If true, use system prompts from snapshot instead of current config (default: false)
    def initialize(orchestration, snapshot, preserve_system_prompts: false)
      @orchestration = orchestration
      @preserve_system_prompts = preserve_system_prompts

      # Handle different input types
      @snapshot_data = case snapshot
      when Snapshot
        snapshot.to_hash
      when String
        JSON.parse(snapshot, symbolize_names: true)
      when Hash
        snapshot
      else
        raise ArgumentError, "snapshot must be a Snapshot object, Hash, or JSON string"
      end

      validate_version!
      validate_type_match!
    end

    # Restore state from snapshot
    #
    # Three-phase process:
    # 1. Validate compatibility (which agents can be restored)
    # 2. Restore state (only for matched agents)
    # 3. Return result with warnings about skipped agents
    #
    # @return [RestoreResult] Result with warnings about partial restores
    def restore
      # Phase 1: Validate compatibility
      validation = validate_compatibility

      # Phase 2: Restore state (only for matched agents)
      restore_metadata
      restore_agent_conversations(validation.restorable_agents)
      restore_delegation_conversations(validation.restorable_delegations)
      restore_scratchpad
      restore_read_tracking
      restore_plugin_states

      # Phase 3: Return result with warnings
      SwarmSDK::RestoreResult.new(
        warnings: validation.warnings,
        skipped_agents: validation.skipped_agents,
        skipped_delegations: validation.skipped_delegations,
      )
    end

    private

    # Validate snapshot version
    #
    # @raise [StateError] if version is unsupported
    def validate_version!
      version = @snapshot_data[:version] || @snapshot_data["version"]
      unless version == "2.1.0"
        raise StateError, "Unsupported snapshot version: #{version}. Expected: 2.1.0"
      end
    end

    # Validate snapshot type matches orchestration type
    #
    # @raise [StateError] if types don't match
    def validate_type_match!
      snapshot_type = (@snapshot_data[:type] || @snapshot_data["type"]).to_s.downcase
      actual_type = @orchestration.class.name.split("::").last.downcase

      unless snapshot_type == actual_type
        raise StateError, "Snapshot type '#{snapshot_type}' doesn't match orchestration type '#{actual_type}'"
      end
    end

    # Validate compatibility between snapshot and current configuration
    #
    # @return [ValidationResult] Validation results
    def validate_compatibility
      warnings = []
      skipped_agents = []
      restorable_agents = []
      skipped_delegations = []
      restorable_delegations = []

      # Get current agent names from configuration
      current_agents = Set.new(@orchestration.agent_definitions.keys)

      # Check each snapshot agent
      snapshot_agents = @snapshot_data[:agents] || @snapshot_data["agents"]
      snapshot_agents.keys.each do |agent_name|
        agent_name_sym = agent_name.to_sym

        if current_agents.include?(agent_name_sym)
          restorable_agents << agent_name_sym
        else
          skipped_agents << agent_name_sym
          warnings << {
            type: :agent_not_found,
            agent: agent_name,
            message: "Agent '#{agent_name}' in snapshot not found in current configuration. " \
              "Conversation will not be restored.",
          }
        end
      end

      # Check delegation instances
      delegation_instances = @snapshot_data[:delegation_instances] || @snapshot_data["delegation_instances"]
      delegation_instances&.each do |instance_name, _data|
        base_name, delegator_name = instance_name.split("@")

        # Delegation can be restored if both agents exist in current configuration
        if current_agents.include?(base_name.to_sym) &&
            restorable_agents.include?(delegator_name.to_sym)
          restorable_delegations << instance_name
        else
          skipped_delegations << instance_name
          warnings << {
            type: :delegation_instance_not_restorable,
            instance: instance_name,
            message: "Delegation instance '#{instance_name}' cannot be restored " \
              "(base agent or delegator not in current swarm/workflow).",
          }
        end
      end

      SwarmSDK::ValidationResult.new(
        warnings: warnings,
        skipped_agents: skipped_agents,
        restorable_agents: restorable_agents,
        skipped_delegations: skipped_delegations,
        restorable_delegations: restorable_delegations,
      )
    end

    # Restore orchestration metadata
    #
    # @return [void]
    def restore_metadata
      # Restore metadata
      metadata = @snapshot_data[:metadata] || @snapshot_data["metadata"]
      return unless metadata

      # Restore first_message_sent flag (Swarm only, no-op for Workflow)
      if @orchestration.respond_to?(:first_message_sent=)
        first_sent = metadata[:first_message_sent] || metadata["first_message_sent"]
        @orchestration.first_message_sent = first_sent
      end
    end

    # Restore agent conversations
    #
    # Uses interface methods - no type checking!
    #
    # @param restorable_agents [Array<Symbol>] Agents that can be restored
    # @return [void]
    def restore_agent_conversations(restorable_agents)
      restorable_agents.each do |agent_name|
        # For Swarm: lazy initialization triggers when we call agent()
        # For Workflow: agents are in cache if already used, otherwise skip
        agent_chat = if @orchestration.is_a?(Swarm)
          @orchestration.agent(agent_name)
        else
          # Workflow: only restore if agent is already in cache
          @orchestration.primary_agents[agent_name]
        end

        next unless agent_chat

        # Get agent snapshot data
        agents_data = @snapshot_data[:agents] || @snapshot_data["agents"]
        snapshot_data = agents_data[agent_name] || agents_data[agent_name.to_s]
        next unless snapshot_data

        # Restore conversation
        restore_agent_conversation(agent_chat, agent_name, snapshot_data)
      end
    end

    # Restore a single agent's conversation
    #
    # @param agent_chat [Agent::Chat] Chat instance
    # @param agent_name [Symbol] Agent name
    # @param snapshot_data [Hash] Snapshot data for this agent
    # @return [void]
    def restore_agent_conversation(agent_chat, agent_name, snapshot_data)
      # Determine which system prompt to use
      system_prompt = if @preserve_system_prompts
        snapshot_data[:system_prompt] || snapshot_data["system_prompt"]
      else
        agent_definition = @orchestration.agent_definitions[agent_name]
        agent_definition&.system_prompt
      end

      # Build complete message list including system message
      all_messages = []

      # Add system message first if we have a system prompt
      if system_prompt
        all_messages << RubyLLM::Message.new(role: :system, content: system_prompt)
      end

      # Add conversation messages
      conversation = snapshot_data[:conversation] || snapshot_data["conversation"]
      restored_messages = conversation.map { |msg_data| deserialize_message(msg_data) }
      all_messages.concat(restored_messages)

      # Replace all messages using proper abstraction
      agent_chat.replace_messages(all_messages)

      # Restore context state
      context_state = snapshot_data[:context_state] || snapshot_data["context_state"]
      restore_context_state(agent_chat, context_state)
    end

    # Deserialize a message from snapshot data
    #
    # @param msg_data [Hash] Message data from snapshot
    # @return [RubyLLM::Message] Deserialized message
    def deserialize_message(msg_data)
      # Handle Content objects
      content = if msg_data[:content].is_a?(Hash) && (msg_data[:content].key?(:text) || msg_data[:content].key?("text"))
        content_data = msg_data[:content]
        text = content_data[:text] || content_data["text"]
        attachments = content_data[:attachments] || content_data["attachments"] || []

        RubyLLM::Content.new(text, attachments)
      else
        msg_data[:content]
      end

      # Handle tool calls
      tool_calls_hash = if msg_data[:tool_calls] && !msg_data[:tool_calls].empty?
        msg_data[:tool_calls].each_with_object({}) do |tc_data, hash|
          id = tc_data[:id] || tc_data["id"]
          name = tc_data[:name] || tc_data["name"]
          arguments = tc_data[:arguments] || tc_data["arguments"] || {}

          hash[id.to_s] = RubyLLM::ToolCall.new(
            id: id,
            name: name,
            arguments: arguments,
          )
        end
      end

      RubyLLM::Message.new(
        role: (msg_data[:role] || msg_data["role"]).to_sym,
        content: content,
        tool_calls: tool_calls_hash,
        tool_call_id: msg_data[:tool_call_id] || msg_data["tool_call_id"],
        input_tokens: msg_data[:input_tokens] || msg_data["input_tokens"],
        output_tokens: msg_data[:output_tokens] || msg_data["output_tokens"],
        model_id: msg_data[:model_id] || msg_data["model_id"],
      )
    end

    # Restore context state for an agent
    #
    # @param agent_chat [Agent::Chat] Agent chat instance
    # @param context_state [Hash] Context state data
    # @return [void]
    def restore_context_state(agent_chat, context_state)
      context_manager = agent_chat.context_manager
      agent_context = agent_chat.agent_context

      # Restore warning thresholds
      if context_state[:warning_thresholds_hit] || context_state["warning_thresholds_hit"]
        thresholds_array = context_state[:warning_thresholds_hit] || context_state["warning_thresholds_hit"]
        thresholds_set = agent_context.warning_thresholds_hit
        thresholds_array.each { |t| thresholds_set.add(t) }
      end

      # Restore compression flag
      compression = context_state[:compression_applied] || context_state["compression_applied"]
      context_manager.compression_applied = compression

      # Restore TodoWrite tracking
      todowrite_index = context_state[:last_todowrite_message_index] || context_state["last_todowrite_message_index"]
      agent_chat.last_todowrite_message_index = todowrite_index

      # Restore active skill path
      skill_path = context_state[:active_skill_path] || context_state["active_skill_path"]
      agent_chat.active_skill_path = skill_path
    end

    # Restore delegation instance conversations
    #
    # Uses interface methods - no type checking!
    #
    # @param restorable_delegations [Array<String>] Delegation instances that can be restored
    # @return [void]
    def restore_delegation_conversations(restorable_delegations)
      restorable_delegations.each do |instance_name|
        # Use interface method - works for both!
        delegation_chat = @orchestration.delegation_instances_hash[instance_name]
        next unless delegation_chat

        # Get delegation snapshot data
        delegations_data = @snapshot_data[:delegation_instances] || @snapshot_data["delegation_instances"]
        snapshot_data = delegations_data[instance_name.to_sym] || delegations_data[instance_name.to_s] || delegations_data[instance_name]
        next unless snapshot_data

        # Extract base agent name
        base_name = instance_name.to_s.split("@").first.to_sym

        # Restore conversation
        restore_delegation_conversation(delegation_chat, base_name, snapshot_data)
      end
    end

    # Restore a single delegation's conversation
    #
    # @param delegation_chat [Agent::Chat] Chat instance
    # @param base_name [Symbol] Base agent name
    # @param snapshot_data [Hash] Snapshot data
    # @return [void]
    def restore_delegation_conversation(delegation_chat, base_name, snapshot_data)
      # Determine which system prompt to use
      system_prompt = if @preserve_system_prompts
        snapshot_data[:system_prompt] || snapshot_data["system_prompt"]
      else
        agent_definition = @orchestration.agent_definitions[base_name]
        agent_definition&.system_prompt
      end

      # Build complete message list including system message
      all_messages = []

      # Add system message first if we have a system prompt
      if system_prompt
        all_messages << RubyLLM::Message.new(role: :system, content: system_prompt)
      end

      # Restore conversation messages
      conversation = snapshot_data[:conversation] || snapshot_data["conversation"]
      restored_messages = conversation.map { |msg_data| deserialize_message(msg_data) }
      all_messages.concat(restored_messages)

      # Replace all messages using proper abstraction
      delegation_chat.replace_messages(all_messages)

      # Restore context state
      context_state = snapshot_data[:context_state] || snapshot_data["context_state"]
      restore_context_state(delegation_chat, context_state)
    end

    # Restore scratchpad contents
    #
    # @return [void]
    def restore_scratchpad
      scratchpad_data = @snapshot_data[:scratchpad] || @snapshot_data["scratchpad"]
      return unless scratchpad_data&.any?

      if @orchestration.is_a?(Workflow)
        restore_workflow_scratchpad(scratchpad_data)
      else
        restore_swarm_scratchpad(scratchpad_data)
      end
    end

    # Restore scratchpad for Workflow
    #
    # @param scratchpad_data [Hash] { shared: bool, data: ... }
    # @return [void]
    def restore_workflow_scratchpad(scratchpad_data)
      snapshot_shared_mode = scratchpad_data[:shared] || scratchpad_data["shared"]
      data = scratchpad_data[:data] || scratchpad_data["data"]

      return unless data&.any?

      # Warn if snapshot mode doesn't match current configuration
      if snapshot_shared_mode != @orchestration.shared_scratchpad?
        RubyLLM.logger.warn(
          "SwarmSDK: Scratchpad mode mismatch: snapshot=#{snapshot_shared_mode ? "enabled" : "per_node"}, " \
            "current=#{@orchestration.shared_scratchpad? ? "enabled" : "per_node"}",
        )
        RubyLLM.logger.warn("SwarmSDK: Restoring anyway - data may not behave as expected")
      end

      if snapshot_shared_mode
        # Restore shared scratchpad
        shared_scratchpad = @orchestration.scratchpad_for(@orchestration.start_node)
        shared_scratchpad&.restore_entries(data)
      else
        # Restore per-node scratchpads
        data.each do |node_name, entries|
          next unless entries&.any?

          scratchpad = @orchestration.scratchpad_for(node_name.to_sym)
          scratchpad&.restore_entries(entries)
        end
      end
    end

    # Restore scratchpad for Swarm
    #
    # @param scratchpad_data [Hash] Flat scratchpad entries
    # @return [void]
    def restore_swarm_scratchpad(scratchpad_data)
      scratchpad = @orchestration.scratchpad_storage
      return unless scratchpad

      scratchpad.restore_entries(scratchpad_data)
    end

    # Restore read tracking state
    #
    # @return [void]
    def restore_read_tracking
      read_tracking_data = @snapshot_data[:read_tracking] || @snapshot_data["read_tracking"]
      return unless read_tracking_data

      read_tracking_data.each do |agent_name, files_with_digests|
        agent_sym = agent_name.to_sym
        Tools::Stores::ReadTracker.restore_read_files(agent_sym, files_with_digests)
      end
    end

    # Restore plugin-specific state for all plugins
    #
    # @return [void]
    def restore_plugin_states
      plugin_states_data = @snapshot_data[:plugin_states] || @snapshot_data["plugin_states"]
      return unless plugin_states_data

      plugin_states_data.each do |plugin_name, agents_state|
        # Find plugin by name
        plugin = PluginRegistry.all.find { |p| p.name.to_s == plugin_name.to_s }
        next unless plugin

        # Restore state for each agent
        agents_state.each do |agent_name, state|
          agent_sym = agent_name.to_sym
          # Symbolize keys for consistent access
          symbolized_state = state.is_a?(Hash) ? state.transform_keys(&:to_sym) : state
          plugin.restore_agent_state(agent_sym, symbolized_state)
        end
      end
    end
  end
end
