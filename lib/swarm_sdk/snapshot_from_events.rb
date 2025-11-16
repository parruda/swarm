# frozen_string_literal: true

module SwarmSDK
  # Reconstructs a complete StateSnapshot from event logs
  #
  # This class enables full swarm state reconstruction from event streams,
  # supporting session persistence, time travel debugging, and event sourcing.
  #
  # ## Usage
  #
  #   # Collect events during execution
  #   events = []
  #   swarm.execute("Build feature") { |event| events << event }
  #
  #   # Save events to storage (DB, file, Redis, etc.)
  #   File.write("session.json", JSON.generate(events))
  #
  #   # Later: Reconstruct snapshot from events
  #   events = JSON.parse(File.read("session.json"), symbolize_names: true)
  #   snapshot_data = SwarmSDK::SnapshotFromEvents.reconstruct(events)
  #
  #   # Restore swarm from reconstructed snapshot
  #   swarm = SwarmSDK::Swarm.from_config("swarm.yml")
  #   swarm.restore(snapshot_data)
  #
  # ## What Gets Reconstructed
  #
  # - Swarm metadata (swarm_id, parent_swarm_id, first_message_sent)
  # - Agent conversations (all RubyLLM::Message objects)
  # - Agent context state (warnings, compression, todowrite, skills)
  # - Delegation instance conversations
  # - Scratchpad contents
  # - Read tracking with digests
  # - Memory read tracking with digests
  #
  # ## Requirements
  #
  # Events must have:
  # - :timestamp field (ISO 8601 format) for chronological ordering
  # - :agent field to identify which agent
  # - :type field to identify event type
  #
  # @see EventsToMessages for message reconstruction details
  class SnapshotFromEvents
    class << self
      # Reconstruct a complete StateSnapshot from event stream
      #
      # @param events [Array<Hash>] Event stream with timestamps
      # @return [Hash] Complete StateSnapshot hash compatible with StateRestorer
      #
      # @example
      #   snapshot_data = SnapshotFromEvents.reconstruct(events)
      #   swarm.restore(snapshot_data)
      def reconstruct(events)
        new(events).reconstruct
      end
    end

    # Initialize reconstructor
    #
    # @param events [Array<Hash>] Event stream
    def initialize(events)
      # Sort events by timestamp for chronological processing
      @events = events.sort_by { |e| parse_timestamp(e[:timestamp]) }
    end

    # Reconstruct complete snapshot
    #
    # @return [Hash] StateSnapshot hash
    def reconstruct
      {
        version: "2.1.0",
        type: "swarm",
        snapshot_at: @events.last&.fetch(:timestamp, Time.now.utc.iso8601),
        swarm_sdk_version: SwarmSDK::VERSION,
        metadata: reconstruct_swarm_metadata,
        agents: reconstruct_all_agents,
        delegation_instances: reconstruct_all_delegations,
        scratchpad: reconstruct_scratchpad,
        read_tracking: reconstruct_read_tracking,
        memory_read_tracking: reconstruct_memory_read_tracking,
        plugin_states: reconstruct_plugin_states,
      }
    end

    private

    # Reconstruct swarm metadata
    #
    # @return [Hash] Swarm metadata
    def reconstruct_swarm_metadata
      first_event = @events.first || {}

      {
        id: first_event[:swarm_id],
        parent_id: first_event[:parent_swarm_id],
        first_message_sent: !@events.empty?,
      }
    end

    # Reconstruct all primary agents
    #
    # @return [Hash] { agent_name => { conversation:, context_state:, system_prompt: } }
    def reconstruct_all_agents
      # Get unique primary agent names (exclude delegations with @)
      agent_names = @events
        .map { |e| e[:agent] }
        .compact
        .uniq
        .reject { |name| name.to_s.include?("@") }

      agent_names.each_with_object({}) do |agent, hash|
        hash[agent.to_s] = {
          conversation: reconstruct_conversation(agent),
          context_state: reconstruct_context_state(agent),
          system_prompt: reconstruct_system_prompt(agent),
        }
      end
    end

    # Reconstruct all delegation instances
    #
    # @return [Hash] { "delegate@delegator" => { conversation:, context_state:, system_prompt: } }
    def reconstruct_all_delegations
      # Get unique delegation instance names (contain @)
      delegation_names = @events
        .map { |e| e[:agent] }
        .compact
        .uniq
        .select { |name| name.to_s.include?("@") }

      delegation_names.each_with_object({}) do |delegation, hash|
        hash[delegation.to_s] = {
          conversation: reconstruct_conversation(delegation),
          context_state: reconstruct_context_state(delegation),
          system_prompt: reconstruct_system_prompt(delegation),
        }
      end
    end

    # Reconstruct conversation for an agent
    #
    # @param agent [Symbol, String] Agent name
    # @return [Array<Hash>] Serialized RubyLLM::Message objects
    def reconstruct_conversation(agent)
      messages = SwarmSDK::EventsToMessages.reconstruct(@events, agent: agent)
      messages.map { |msg| serialize_message(msg) }
    end

    # Serialize a RubyLLM::Message to hash format
    #
    # Matches the format used by StateSnapshot.
    #
    # @param msg [RubyLLM::Message] Message to serialize
    # @return [Hash] Serialized message
    def serialize_message(msg)
      hash = { role: msg.role, content: msg.content }

      # Serialize tool calls if present
      # Must manually extract fields - RubyLLM::ToolCall#to_h doesn't reliably serialize id/name
      # msg.tool_calls is a Hash<String, ToolCall>, so we need .values
      if msg.tool_calls && !msg.tool_calls.empty?
        hash[:tool_calls] = msg.tool_calls.values.map do |tc|
          {
            id: tc.id,
            name: tc.name,
            arguments: tc.arguments,
          }
        end
      end

      # Add optional fields
      hash[:tool_call_id] = msg.tool_call_id if msg.tool_call_id
      hash[:input_tokens] = msg.input_tokens if msg.input_tokens
      hash[:output_tokens] = msg.output_tokens if msg.output_tokens
      hash[:model_id] = msg.model_id if msg.model_id

      hash
    end

    # Reconstruct context state for an agent
    #
    # @param agent [Symbol, String] Agent name
    # @return [Hash] Context state
    def reconstruct_context_state(agent)
      {
        warning_thresholds_hit: reconstruct_warning_thresholds(agent),
        compression_applied: reconstruct_compression_applied(agent),
        last_todowrite_message_index: reconstruct_todowrite_index(agent),
        active_skill_path: reconstruct_active_skill_path(agent),
      }
    end

    # Reconstruct which warning thresholds were hit
    #
    # @param agent [Symbol, String] Agent name
    # @return [Array<Integer>] Sorted array of thresholds that were hit
    def reconstruct_warning_thresholds(agent)
      @events
        .select { |e| e[:type] == "context_threshold_hit" && normalize_agent(e[:agent]) == normalize_agent(agent) }
        .map { |e| e[:threshold] }
        .uniq
        .sort
    end

    # Reconstruct compression state
    #
    # @param agent [Symbol, String] Agent name
    # @return [Boolean, nil] true if compression was applied, nil otherwise
    def reconstruct_compression_applied(agent)
      compression_event = @events
        .select { |e| e[:type] == "compression_completed" && normalize_agent(e[:agent]) == normalize_agent(agent) }
        .last

      # NOTE: StateSnapshot stores nil (not false) when no compression applied
      compression_event ? true : nil
    end

    # Reconstruct last TodoWrite message index
    #
    # Finds the last TodoWrite tool call and determines which message index it corresponds to.
    #
    # @param agent [Symbol, String] Agent name
    # @return [Integer, nil] Message index or nil if no TodoWrite calls
    def reconstruct_todowrite_index(agent)
      # Find last TodoWrite tool call
      last_todowrite_call = @events
        .select { |e| e[:type] == "tool_call" && e[:tool] == "TodoWrite" && normalize_agent(e[:agent]) == normalize_agent(agent) }
        .sort_by { |e| parse_timestamp(e[:timestamp]) }
        .last

      return unless last_todowrite_call

      # Reconstruct messages to find index
      messages = SwarmSDK::EventsToMessages.reconstruct(@events, agent: agent)

      # Find the message containing this tool_call_id
      messages.each_with_index do |msg, idx|
        if msg.role == :assistant && msg.tool_calls
          return idx if msg.tool_calls.key?(last_todowrite_call[:tool_call_id])
        end
      end

      nil
    end

    # Reconstruct active skill path
    #
    # @param agent [Symbol, String] Agent name
    # @return [String, nil] Skill path or nil if no skill loaded
    def reconstruct_active_skill_path(agent)
      last_load_skill = @events
        .select { |e| e[:type] == "tool_call" && e[:tool] == "LoadSkill" && normalize_agent(e[:agent]) == normalize_agent(agent) }
        .sort_by { |e| parse_timestamp(e[:timestamp]) }
        .last

      return unless last_load_skill

      # Extract skill path from arguments (handle both symbol and string keys)
      args = last_load_skill[:arguments]
      args[:file_path] || args["file_path"]
    end

    # Reconstruct system prompt from the last agent_start event
    #
    # Uses the LAST agent_start event for this agent, which represents the most
    # recent system prompt that was active. This handles cases where the swarm
    # was restarted with updated configuration.
    #
    # @param agent [Symbol, String] Agent name
    # @return [String, nil] System prompt or nil if no agent_start event found
    def reconstruct_system_prompt(agent)
      last_agent_start = @events
        .select { |e| e[:type] == "agent_start" && normalize_agent(e[:agent]) == normalize_agent(agent) }
        .sort_by { |e| parse_timestamp(e[:timestamp]) }
        .last

      return unless last_agent_start

      # Handle both symbol and string keys from JSON
      last_agent_start[:system_prompt] || last_agent_start["system_prompt"]
    end

    # Reconstruct scratchpad contents
    #
    # Replays all ScratchpadWrite tool calls in chronological order.
    # Later writes to the same path overwrite earlier ones.
    #
    # @return [Hash] { path => { content:, title:, updated_at:, size: } }
    def reconstruct_scratchpad
      scratchpad = {}

      @events
        .select { |e| e[:type] == "tool_call" && e[:tool] == "ScratchpadWrite" }
        .sort_by { |e| parse_timestamp(e[:timestamp]) }
        .each do |event|
          args = event[:arguments]

          # Handle both symbol and string keys
          path = args[:file_path] || args["file_path"]
          content = args[:content] || args["content"]
          title = args[:title] || args["title"]

          next unless path && content

          scratchpad[path] = {
            content: content,
            title: title,
            updated_at: event[:timestamp],
            size: content.bytesize,
          }
        end

      scratchpad
    end

    # Reconstruct read tracking (file digests)
    #
    # Extracts digests from Read tool_result metadata.
    # Later reads to the same file update the digest.
    #
    # @return [Hash] { agent_name => { file_path => digest } }
    def reconstruct_read_tracking
      tracking = {}

      @events
        .select { |e| e[:type] == "tool_result" && e[:tool] == "Read" }
        .each do |event|
          agent = event[:agent].to_s # Use string key to match StateSnapshot format
          digest = event.dig(:metadata, :read_digest)
          path = event.dig(:metadata, :read_path)

          next unless digest && path

          tracking[agent] ||= {}
          tracking[agent][path] = digest
        end

      tracking
    end

    # Reconstruct memory read tracking (entry digests)
    #
    # Extracts digests from MemoryRead tool_result metadata.
    # Later reads to the same entry update the digest.
    #
    # @return [Hash] { agent_name => { entry_path => digest } }
    def reconstruct_memory_read_tracking
      tracking = {}

      @events
        .select { |e| e[:type] == "tool_result" && e[:tool] == "MemoryRead" }
        .each do |event|
          agent = event[:agent].to_s # Use string key to match StateSnapshot format
          digest = event.dig(:metadata, :read_digest)
          path = event.dig(:metadata, :read_path)

          next unless digest && path

          tracking[agent] ||= {}
          tracking[agent][path] = digest
        end

      tracking
    end

    # Reconstruct plugin states
    #
    # Plugin states cannot be fully reconstructed from events alone as they
    # contain internal plugin data. Returns empty hash for compatibility.
    #
    # @return [Hash] Empty plugin states hash
    def reconstruct_plugin_states
      {}
    end

    # Parse timestamp string to Time object
    #
    # @param timestamp [String, nil] ISO 8601 timestamp
    # @return [Time] Parsed time or epoch if nil/invalid
    def parse_timestamp(timestamp)
      return Time.at(0) unless timestamp

      Time.parse(timestamp)
    rescue ArgumentError
      Time.at(0)
    end

    # Normalize agent name for comparison
    #
    # @param agent [Symbol, String, nil] Agent name
    # @return [Symbol] Normalized agent name
    def normalize_agent(agent)
      agent.to_s.to_sym
    end
  end
end
