# frozen_string_literal: true

module SwarmSDK
  module Observer
    # DSL for configuring observer agents
    #
    # Used by Swarm::Builder#observer to provide a clean DSL for defining
    # event handlers and observer configuration options.
    #
    # @example Basic usage
    #   observer :profiler do
    #     on :swarm_start do |event|
    #       "Analyze this prompt: #{event[:prompt]}"
    #     end
    #
    #     timeout 120
    #     max_concurrent 2
    #   end
    class Builder
      # Initialize builder with agent name and config
      #
      # @param agent_name [Symbol] Name of the observer agent
      # @param config [Observer::Config] Configuration object to populate
      def initialize(agent_name, config)
        @agent_name = agent_name
        @config = config
      end

      # Register an event handler
      #
      # The block receives the event hash and should return:
      # - A prompt string to trigger the observer agent
      # - nil to skip execution for this event
      #
      # @param event_type [Symbol] Type of event to handle (e.g., :swarm_start, :tool_call)
      # @yield [Hash] Event hash
      # @yieldreturn [String, nil] Prompt or nil to skip
      # @return [void]
      #
      # @example
      #   on :tool_call do |event|
      #     next unless event[:tool_name] == "Bash"
      #     "Check this command: #{event[:arguments][:command]}"
      #   end
      def on(event_type, &block)
        @config.add_handler(event_type, &block)
      end

      # Set maximum concurrent executions for this observer
      #
      # Limits how many instances of this observer agent can run simultaneously.
      # Useful for resource-intensive observers.
      #
      # @param n [Integer] Maximum concurrent executions
      # @return [void]
      def max_concurrent(n)
        @config.options[:max_concurrent] = n
      end

      # Set timeout for observer execution
      #
      # Observer tasks will be cancelled after this duration.
      #
      # @param seconds [Integer] Timeout in seconds (default: 60)
      # @return [void]
      def timeout(seconds)
        @config.options[:timeout] = seconds
      end

      # Wait for observer to complete before swarm execution ends
      #
      # By default, observers are fire-and-forget. This option causes
      # the main execution to wait for this observer to complete.
      #
      # @return [void]
      def wait_for_completion!
        @config.options[:fire_and_forget] = false
      end
    end
  end
end
