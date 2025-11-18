# frozen_string_literal: true

module SwarmSDK
  module Patterns
    # Observes another agent's actions with optional real-time processing
    #
    # @example Basic observation
    #   observer = AgentObserver.new(target: :backend)
    #   observer.start
    #   swarm.execute("task")
    #   observer.stop
    #   puts observer.observations
    #
    # @example Real-time analysis
    #   observer = AgentObserver.new(
    #     target: :backend,
    #     on_event: ->(e) { analyze_security(e) }
    #   )
    #
    # @example Filter specific event types
    #   observer = AgentObserver.new(
    #     target: :backend,
    #     event_types: ["tool_call", "tool_result"]
    #   )
    class AgentObserver
      attr_reader :observations, :target_agent

      # Initialize observer
      #
      # @param target [Symbol] Agent to observe
      # @param event_types [Array<String>] Event types to capture (default: all)
      # @param on_event [Proc] Optional callback for real-time processing
      def initialize(target:, event_types: nil, on_event: nil)
        @target_agent = target
        @event_types = event_types
        @on_event = on_event
        @observations = []
        @subscription_id = nil
        @started_at = nil
      end

      # Start observing
      #
      # @return [void]
      def start
        return if @subscription_id

        @started_at = Time.now
        @observations.clear

        filter = { agent: @target_agent }
        filter[:type] = @event_types if @event_types

        @subscription_id = LogCollector.subscribe(filter: filter) do |event|
          @observations << event.merge(observed_at: Time.now)
          @on_event&.call(event)
        end
      end

      # Stop observing
      #
      # @return [void]
      def stop
        return unless @subscription_id

        LogCollector.unsubscribe(@subscription_id)
        @subscription_id = nil
      end

      # Check if currently observing
      #
      # @return [Boolean] true if actively observing
      def observing?
        !@subscription_id.nil?
      end

      # Get summary of observations
      #
      # @return [Hash] Summary statistics
      def summary
        {
          target: @target_agent,
          started_at: @started_at,
          duration_seconds: @started_at ? (Time.now - @started_at).round(2) : 0,
          total_events: @observations.size,
          event_breakdown: @observations.group_by { |e| e[:type] }.transform_values(&:count),
          tool_calls: @observations.select { |e| e[:type] == "tool_call" }.map { |e| e[:tool_name] },
          errors: @observations.select { |e| e[:type] == "internal_error" },
        }
      end

      # Format observations for LLM consumption
      #
      # Useful for providing observation data to another agent for analysis
      #
      # @return [String] Formatted observation log
      def to_llm_context
        @observations.map do |event|
          case event[:type]
          when "tool_call"
            "- Called #{event[:tool_name]} with: #{truncate_json(event[:arguments])}"
          when "tool_result"
            "- #{event[:tool_name]} returned: #{truncate(event[:result])}"
          when "agent_step"
            "- Thinking: #{truncate(event[:content])}"
          when "agent_stop"
            "- Final response: #{truncate(event[:content])}"
          else
            "- [#{event[:type]}] #{event.except(:type, :timestamp, :observed_at).to_json}"
          end
        end.join("\n")
      end

      # Clear collected observations
      #
      # @return [void]
      def clear_observations
        @observations.clear
      end

      # Execute block while observing
      #
      # Automatically starts and stops observation around the block
      #
      # @example
      #   observer = AgentObserver.new(target: :backend)
      #   observer.observe do
      #     swarm.execute("Build API")
      #   end
      #   puts observer.summary
      #
      # @yield Block to execute while observing
      # @return [Object] Result from the block
      def observe
        start
        yield
      ensure
        stop
      end

      private

      def truncate(text, max_length = 200)
        return "" if text.nil?

        text = text.to_s
        return text if text.length <= max_length

        "#{text[0...max_length]}..."
      end

      def truncate_json(obj, max_length = 100)
        return "{}" if obj.nil?

        json = obj.to_json
        truncate(json, max_length)
      end
    end
  end
end
