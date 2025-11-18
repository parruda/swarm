# frozen_string_literal: true

module SwarmSDK
  # Creates snapshots of swarm/workflow conversation state
  #
  # Unified implementation that works for both Swarm and Workflow.
  # Captures conversation history, context state, scratchpad contents, and
  # read tracking information.
  #
  # The snapshot is a plain Ruby hash that can be serialized to JSON or any
  # other format. Configuration (agent definitions, tools, prompts) stays in
  # your YAML/DSL and is not included in snapshots.
  #
  # @example Snapshot a swarm
  #   swarm = SwarmSDK.build { ... }
  #   swarm.execute("Build authentication")
  #   snapshot = swarm.snapshot
  #   snapshot.write_to_file("session.json")
  #
  # @example Snapshot a workflow
  #   workflow = SwarmSDK.workflow { ... }
  #   workflow.execute("Build feature")
  #   snapshot = workflow.snapshot
  #   snapshot.write_to_file("workflow_session.json")
  class StateSnapshot
    # Initialize snapshot creator
    #
    # @param orchestration [Swarm, Workflow] Swarm or workflow to snapshot
    def initialize(orchestration)
      @orchestration = orchestration
    end

    # Create snapshot of current state
    #
    # Returns a Snapshot object that encapsulates the snapshot data with
    # convenient methods for serialization and file I/O.
    #
    # @return [Snapshot] Snapshot object
    def snapshot
      data = {
        version: "2.1.0", # Bumped for plugin state abstraction
        type: type_name,
        snapshot_at: Time.now.utc.iso8601,
        swarm_sdk_version: SwarmSDK::VERSION,
        metadata: snapshot_metadata,
        agents: snapshot_agents,
        delegation_instances: snapshot_delegation_instances,
        scratchpad: snapshot_scratchpad,
        read_tracking: snapshot_read_tracking,
        plugin_states: snapshot_plugin_states,
      }

      # Wrap in Snapshot object
      SwarmSDK::Snapshot.new(data)
    end

    private

    # Get type name for snapshot
    #
    # @return [String] "swarm" or "workflow"
    def type_name
      @orchestration.class.name.split("::").last.downcase
    end

    # Snapshot common metadata
    #
    # @return [Hash] Metadata
    def snapshot_metadata
      {
        id: @orchestration.swarm_id,
        parent_id: @orchestration.parent_swarm_id,
        name: @orchestration.name,
        # Swarm-specific: first_message_sent (Workflow returns false)
        first_message_sent: @orchestration.first_message_sent?,
      }
    end

    # Snapshot all agent conversations and context state
    #
    # Uses interface method: primary_agents (no type checking!)
    #
    # @return [Hash] { agent_name => { conversation:, context_state:, system_prompt: } }
    def snapshot_agents
      result = {}

      # Use interface method - works for both Swarm and Workflow!
      @orchestration.primary_agents.each do |agent_name, agent_chat|
        agent_definition = @orchestration.agent_definitions[agent_name]
        system_prompt = agent_definition&.system_prompt

        result[agent_name.to_s] = {
          conversation: snapshot_conversation(agent_chat),
          context_state: snapshot_context_state(agent_chat),
          system_prompt: system_prompt,
        }
      end

      result
    end

    # Snapshot conversation messages for an agent
    #
    # @param agent_chat [Agent::Chat] Agent chat instance
    # @return [Array<Hash>] Serialized messages
    def snapshot_conversation(agent_chat)
      agent_chat.messages.map { |msg| serialize_message(msg) }
    end

    # Serialize a single message
    #
    # @param msg [RubyLLM::Message] Message to serialize
    # @return [Hash] Serialized message
    def serialize_message(msg)
      hash = { role: msg.role }

      # Handle content - check msg.content directly
      hash[:content] = if msg.content.is_a?(RubyLLM::Content)
        msg.content.to_h
      else
        msg.content
      end

      # Handle tool calls
      if msg.tool_calls && !msg.tool_calls.empty?
        hash[:tool_calls] = msg.tool_calls.values.map do |tc|
          {
            id: tc.id,
            name: tc.name,
            arguments: tc.arguments,
          }
        end
      end

      # Handle other fields
      hash[:tool_call_id] = msg.tool_call_id if msg.tool_call_id
      hash[:input_tokens] = msg.input_tokens if msg.input_tokens
      hash[:output_tokens] = msg.output_tokens if msg.output_tokens
      hash[:model_id] = msg.model_id if msg.model_id

      hash
    end

    # Snapshot context state for an agent
    #
    # @param agent_chat [Agent::Chat] Agent chat instance
    # @return [Hash] Context state
    def snapshot_context_state(agent_chat)
      context_manager = agent_chat.context_manager
      agent_context = agent_chat.agent_context

      {
        warning_thresholds_hit: agent_context.warning_thresholds_hit.to_a,
        compression_applied: context_manager.compression_applied,
        last_todowrite_message_index: agent_chat.last_todowrite_message_index,
        active_skill_path: agent_chat.active_skill_path,
      }
    end

    # Snapshot delegation instance conversations
    #
    # Uses interface method: delegation_instances_hash (no type checking!)
    #
    # @return [Hash] { "delegate@delegator" => { conversation:, context_state:, system_prompt: } }
    def snapshot_delegation_instances
      result = {}

      # Use interface method - works for both Swarm and Workflow!
      @orchestration.delegation_instances_hash.each do |instance_name, delegation_chat|
        # Extract base agent name from instance name
        base_name = instance_name.to_s.split("@").first.to_sym

        # Get system prompt from base agent definition
        agent_definition = @orchestration.agent_definitions[base_name]
        system_prompt = agent_definition&.system_prompt

        result[instance_name] = {
          conversation: snapshot_conversation(delegation_chat),
          context_state: snapshot_context_state(delegation_chat),
          system_prompt: system_prompt,
        }
      end

      result
    end

    # Snapshot scratchpad contents
    #
    # Detects type and calls appropriate method.
    #
    # @return [Hash] Scratchpad snapshot data
    def snapshot_scratchpad
      if @orchestration.is_a?(Workflow)
        snapshot_workflow_scratchpad
      else
        snapshot_swarm_scratchpad
      end
    end

    # Snapshot scratchpad for Workflow
    #
    # @return [Hash] Structured scratchpad data with mode metadata
    def snapshot_workflow_scratchpad
      all_scratchpads = @orchestration.all_scratchpads
      return {} unless all_scratchpads&.any?

      if @orchestration.shared_scratchpad?
        # Enabled mode: single shared scratchpad
        shared_scratchpad = all_scratchpads[:shared]
        return {} unless shared_scratchpad

        entries = serialize_scratchpad_entries(shared_scratchpad.all_entries)
        return {} if entries.empty?

        {
          shared: true,
          data: entries,
        }
      else
        # Per-node mode: separate scratchpads per node
        node_data = {}
        all_scratchpads.each do |node_name, scratchpad|
          next unless scratchpad

          entries = serialize_scratchpad_entries(scratchpad.all_entries)
          node_data[node_name.to_s] = entries unless entries.empty?
        end

        return {} if node_data.empty?

        {
          shared: false,
          data: node_data,
        }
      end
    end

    # Snapshot scratchpad for Swarm
    #
    # @return [Hash] Flat scratchpad entries
    def snapshot_swarm_scratchpad
      scratchpad = @orchestration.scratchpad_storage
      return {} unless scratchpad

      entries_hash = scratchpad.all_entries
      return {} unless entries_hash&.any?

      serialize_scratchpad_entries(entries_hash)
    end

    # Serialize scratchpad entries to snapshot format
    #
    # @param entries_hash [Hash] { path => Entry }
    # @return [Hash] { path => { content:, title:, updated_at:, size: } }
    def serialize_scratchpad_entries(entries_hash)
      return {} unless entries_hash

      result = {}
      entries_hash.each do |path, entry|
        result[path] = {
          content: entry.content,
          title: entry.title,
          updated_at: entry.updated_at.iso8601,
          size: entry.size,
        }
      end
      result
    end

    # Snapshot read tracking state
    #
    # @return [Hash] { agent_name => { file_path => digest } }
    def snapshot_read_tracking
      result = {}

      # Get all agents (primary + delegations)
      agent_names = all_agent_names

      agent_names.each do |agent_name|
        files_with_digests = Tools::Stores::ReadTracker.get_read_files(agent_name)
        next if files_with_digests.empty?

        result[agent_name.to_s] = files_with_digests
      end

      result
    end

    # Snapshot plugin-specific state for all plugins
    #
    # Iterates over all registered plugins and collects their agent-specific state.
    # This decouples the SDK from plugin-specific implementations.
    #
    # @return [Hash] { plugin_name => { agent_name => plugin_state } }
    def snapshot_plugin_states
      result = {}

      # Get all agents (primary + delegations)
      agent_names = all_agent_names

      # Iterate over all registered plugins
      PluginRegistry.all.each do |plugin|
        plugin_state = {}

        agent_names.each do |agent_name|
          agent_state = plugin.snapshot_agent_state(agent_name)
          next if agent_state.empty?

          plugin_state[agent_name.to_s] = agent_state
        end

        # Only include plugin if it has state for at least one agent
        result[plugin.name.to_s] = plugin_state unless plugin_state.empty?
      end

      result
    end

    # All agent names (primary + delegations)
    #
    # Uses interface methods - no type checking!
    #
    # @return [Array<Symbol>] All agent names
    def all_agent_names
      # Get primary agent names
      agents_hash = @orchestration.agent_definitions.keys

      # Add delegation instance names
      delegations_hash = @orchestration.delegation_instances_hash.keys

      agents_hash + delegations_hash.map(&:to_sym)
    end
  end
end
