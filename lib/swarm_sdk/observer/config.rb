# frozen_string_literal: true

module SwarmSDK
  module Observer
    # Configuration for an observer agent
    #
    # Holds the agent name, event handlers (blocks that return prompts or nil),
    # and execution options.
    #
    # @example
    #   config = Observer::Config.new(:profiler)
    #   config.add_handler(:swarm_start) { |event| "Analyze: #{event[:prompt]}" }
    #   config.options[:timeout] = 120
    class Config
      attr_reader :agent_name, :event_handlers, :options

      # Initialize a new observer configuration
      #
      # @param agent_name [Symbol] Name of the agent to use as observer
      def initialize(agent_name)
        @agent_name = agent_name
        @event_handlers = {} # { event_type => block }
        @options = {
          max_concurrent: nil,
          timeout: 60,
          fire_and_forget: true,
        }
      end

      # Add an event handler for a specific event type
      #
      # The block receives the event hash and should return:
      # - A prompt string to trigger the observer agent
      # - nil to skip execution for this event
      #
      # @param event_type [Symbol] Type of event to handle (e.g., :swarm_start, :tool_call)
      # @yield [Hash] Event hash with type, agent, and other data
      # @yieldreturn [String, nil] Prompt to execute or nil to skip
      # @return [void]
      def add_handler(event_type, &block)
        @event_handlers[event_type] = block
      end
    end
  end
end
