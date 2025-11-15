# frozen_string_literal: true

module SwarmSDK
  # Reconstructs RubyLLM::Message objects from SwarmSDK event streams
  #
  # This class enables conversation replay and analysis from event logs.
  # It uses timestamps to maintain chronological ordering of messages.
  #
  # ## Limitations
  #
  # This reconstructs ONLY conversation messages. It does NOT restore:
  # - Context state (warning thresholds, compression, todowrite index)
  # - Scratchpad contents
  # - Read tracking information
  # - Full swarm state
  #
  # For full state restoration, use StateSnapshot/StateRestorer or SnapshotFromEvents.
  #
  # ## Usage
  #
  #   # Collect events during execution
  #   events = []
  #   swarm.execute("Build feature") do |event|
  #     events << event
  #   end
  #
  #   # Reconstruct conversation for an agent
  #   messages = SwarmSDK::EventsToMessages.reconstruct(events, agent: :backend)
  #
  #   # View conversation
  #   messages.each do |msg|
  #     puts "[#{msg.role}] #{msg.content}"
  #   end
  #
  # ## Event Requirements
  #
  # Events must have:
  # - `:timestamp` field (ISO 8601 format) for ordering
  # - `:agent` field to filter by agent
  # - `:type` field to identify event type
  #
  # Supported event types:
  # - `user_prompt`: Reconstructs user message (prompt in metadata or top-level)
  # - `agent_step`: Reconstructs assistant message with tool calls
  # - `agent_stop`: Reconstructs final assistant message
  # - `tool_result`: Reconstructs tool result message
  # - `delegation_result`: Reconstructs tool result message from delegation
  class EventsToMessages
    class << self
      # Reconstruct messages for an agent from event stream
      #
      # @param events [Array<Hash>] Event stream with timestamps
      # @param agent [Symbol, String] Agent name to reconstruct messages for
      # @return [Array<RubyLLM::Message>] Reconstructed messages in chronological order
      #
      # @example
      #   messages = EventsToMessages.reconstruct(events, agent: :backend)
      #   messages.each { |msg| puts msg.content }
      def reconstruct(events, agent:)
        new(events, agent).reconstruct
      end
    end

    # Initialize reconstructor
    #
    # @param events [Array<Hash>] Event stream
    # @param agent [Symbol, String] Agent name
    def initialize(events, agent)
      @events = events
      @agent = agent.to_sym
    end

    # Reconstruct messages from events
    #
    # Filters events by agent, sorts by timestamp, and converts to RubyLLM::Message objects.
    #
    # @return [Array<RubyLLM::Message>] Reconstructed messages
    def reconstruct
      messages = []

      # Filter events for this agent and sort by timestamp
      agent_events = @events
        .select { |e| normalize_agent(e[:agent]) == @agent }
        .sort_by { |e| parse_timestamp(e[:timestamp]) }

      agent_events.each do |event|
        message = case event[:type]&.to_s
        when "user_prompt"
          reconstruct_user_message(event)
        when "agent_step", "agent_stop"
          reconstruct_assistant_message(event)
        when "tool_result"
          reconstruct_tool_result_message(event)
        when "delegation_result"
          reconstruct_delegation_result_message(event)
        end

        messages << message if message
      end

      messages
    end

    private

    # Reconstruct user message from user_prompt event
    #
    # Extracts prompt from metadata or top-level field.
    #
    # @param event [Hash] user_prompt event
    # @return [RubyLLM::Message, nil] User message or nil if prompt not found
    def reconstruct_user_message(event)
      # Try to extract prompt from metadata (current location) or top-level (potential future location)
      prompt = event.dig(:metadata, :prompt) || event[:prompt]
      return unless prompt && !prompt.to_s.empty?

      RubyLLM::Message.new(
        role: :user,
        content: prompt,
      )
    end

    # Reconstruct assistant message from agent_step or agent_stop event
    #
    # Converts tool_calls array to hash format expected by RubyLLM.
    #
    # @param event [Hash] agent_step or agent_stop event
    # @return [RubyLLM::Message] Assistant message
    def reconstruct_assistant_message(event)
      # Convert tool_calls array to hash (RubyLLM format)
      # Events emit tool_calls as Array, but RubyLLM expects Hash<String, ToolCall>
      tool_calls_hash = if event[:tool_calls] && !event[:tool_calls].empty?
        event[:tool_calls].each_with_object({}) do |tc, hash|
          hash[tc[:id].to_s] = RubyLLM::ToolCall.new(
            id: tc[:id],
            name: tc[:name],
            arguments: tc[:arguments] || {},
          )
        end
      end

      RubyLLM::Message.new(
        role: :assistant,
        content: event[:content] || "",
        tool_calls: tool_calls_hash,
        input_tokens: event.dig(:usage, :input_tokens),
        output_tokens: event.dig(:usage, :output_tokens),
        model_id: event[:model],
      )
    end

    # Reconstruct tool result message from tool_result event
    #
    # @param event [Hash] tool_result event
    # @return [RubyLLM::Message] Tool result message
    def reconstruct_tool_result_message(event)
      RubyLLM::Message.new(
        role: :tool,
        content: event[:result].to_s,
        tool_call_id: event[:tool_call_id],
      )
    end

    # Reconstruct tool result message from delegation_result event
    #
    # delegation_result events are emitted when a delegation completes,
    # and they should be converted to tool result messages in the conversation.
    #
    # @param event [Hash] delegation_result event
    # @return [RubyLLM::Message] Tool result message
    def reconstruct_delegation_result_message(event)
      RubyLLM::Message.new(
        role: :tool,
        content: event[:result].to_s,
        tool_call_id: event[:tool_call_id],
      )
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

    # Normalize agent name to symbol
    #
    # @param agent [Symbol, String, nil] Agent name
    # @return [Symbol] Normalized agent name
    def normalize_agent(agent)
      agent.to_s.to_sym
    end
  end
end
