# frozen_string_literal: true

module SwarmSDK
  # LogCollector manages subscriber callbacks for log events with filtering support.
  #
  # This module acts as an emitter implementation that forwards events
  # to user-registered callbacks. It's designed to be set as the LogStream
  # emitter during swarm execution.
  #
  # ## Features
  #
  # - **Filtered Subscriptions**: Subscribe to specific agents, event types, or swarm IDs
  # - **Unsubscribe Support**: Remove subscriptions by ID to prevent memory leaks
  # - **Error Isolation**: One subscriber's error doesn't break others
  # - **Thread Safety**: Fiber-local storage for multi-threaded environments
  #
  # ## Thread Safety for Multi-Threaded Environments (Puma, Sidekiq)
  #
  # Subscriptions are stored in Fiber-local storage (Fiber[:log_subscriptions]) instead
  # of class instance variables. This ensures callbacks registered in the parent
  # thread/fiber are accessible to child fibers created by Async reactor.
  #
  # Why: In Puma/Sidekiq, class instance variables (@subscriptions) are thread-isolated
  # and don't properly propagate to child fibers. Using Fiber-local storage ensures
  # events emitted from within Async blocks can reach registered subscriptions.
  #
  # Child fibers inherit parent fiber-local storage automatically, so events
  # emitted from agent callbacks (on_tool_call, on_end_message, etc.) executing
  # in child fibers can still reach the parent's registered subscriptions.
  #
  # ## Usage
  #
  #   # Subscribe to all events
  #   sub_id = LogCollector.subscribe { |event| puts event }
  #
  #   # Subscribe to specific agent
  #   sub_id = LogCollector.subscribe(filter: { agent: :backend }) { |event|
  #     puts "Backend: #{event}"
  #   }
  #
  #   # Subscribe to specific event types
  #   sub_id = LogCollector.subscribe(filter: { type: ["tool_call", "tool_result"] }) { |event|
  #     log_tool_activity(event)
  #   }
  #
  #   # Subscribe with regex matching
  #   sub_id = LogCollector.subscribe(filter: { type: /^tool_/ }) { |event|
  #     track_tool_usage(event)
  #   }
  #
  #   # Unsubscribe when done
  #   LogCollector.unsubscribe(sub_id)
  #
  #   # After execution, reset for next use
  #   LogCollector.reset!
  #
  module LogCollector
    # Subscription object with filtering capabilities
    #
    # Encapsulates a callback with optional filters. Filters can match
    # against agent name, event type, swarm_id, or any event field.
    class Subscription
      attr_reader :id, :filter, :callback

      # Initialize a subscription
      #
      # @param filter [Hash] Filter criteria
      # @param callback [Proc] Block to call when event matches
      def initialize(filter: {}, &callback)
        @id = SecureRandom.uuid
        @filter = normalize_filter(filter)
        @callback = callback
      end

      # Check if event matches filter criteria
      #
      # Empty filter matches all events. Multiple filter keys are AND'd together.
      #
      # @param event [Hash] Event entry with :type, :agent, etc.
      # @return [Boolean] True if event matches filter
      def matches?(event)
        return true if @filter.empty?

        @filter.all? do |key, matcher|
          value = event[key]
          case matcher
          when Array
            # Match if value is in array (handles symbols/strings)
            matcher.include?(value) || matcher.map(&:to_s).include?(value.to_s)
          when Regexp
            # Regex matching
            value.to_s.match?(matcher)
          when Proc
            # Custom matcher
            matcher.call(value)
          else
            # Exact match (handles symbols/strings)
            matcher == value || matcher.to_s == value.to_s
          end
        end
      end

      private

      # Normalize filter keys to symbols for consistent matching
      #
      # @param filter [Hash] Raw filter
      # @return [Hash] Normalized filter with symbol keys
      def normalize_filter(filter)
        filter.transform_keys(&:to_sym)
      end
    end

    class << self
      # Subscribe to log events with optional filtering
      #
      # Registers a callback that will receive events matching the filter criteria.
      # Returns a subscription ID that can be used to unsubscribe later.
      #
      # @param filter [Hash] Filter criteria (empty = all events)
      #   - :agent [Symbol, String, Array, Regexp] Agent name(s) to observe
      #   - :type [String, Array, Regexp] Event type(s) to receive
      #   - :swarm_id [String] Specific swarm instance
      #   - Any other key matches against event fields
      # @yield [Hash] Log event entry
      # @return [String] Subscription ID for unsubscribe
      #
      # @example Subscribe to all events
      #   LogCollector.subscribe { |event| puts event }
      #
      # @example Subscribe to specific agent's tool calls
      #   sub_id = LogCollector.subscribe(
      #     filter: { agent: :backend, type: /^tool_/ }
      #   ) do |event|
      #     puts "Backend used tool: #{event[:tool]}"
      #   end
      #
      # @example Subscribe to multiple agents
      #   LogCollector.subscribe(
      #     filter: { agent: [:backend, :frontend], type: "agent_stop" }
      #   ) { |e| record_completion(e) }
      def subscribe(filter: {}, &block)
        subscription = Subscription.new(filter: filter, &block)
        subscriptions << subscription
        subscription.id
      end

      # Unsubscribe by ID
      #
      # Removes a subscription to prevent memory leaks and stop receiving events.
      #
      # @param subscription_id [String] ID returned from subscribe
      # @return [Subscription, nil] Removed subscription or nil if not found
      def unsubscribe(subscription_id)
        index = subscriptions.find_index { |s| s.id == subscription_id }
        return unless index

        subscriptions.delete_at(index)
      end

      # Clear all subscriptions
      #
      # Removes all subscriptions. Useful for testing or execution cleanup.
      #
      # @return [void]
      def clear_subscriptions
        subscriptions.clear
      end

      # Get current subscription count
      #
      # @return [Integer] Number of active subscriptions
      def subscription_count
        subscriptions.size
      end

      # Emit an event to all matching subscribers
      #
      # Automatically adds a timestamp if one doesn't exist.
      # Errors in individual subscribers are isolated - one bad subscriber
      # won't prevent others from receiving events.
      #
      # @param entry [Hash] Log event entry
      # @return [void]
      def emit(entry)
        entry_with_timestamp = ensure_timestamp(entry)

        subscriptions.each do |subscription|
          next unless subscription.matches?(entry_with_timestamp)

          begin
            subscription.callback.call(entry_with_timestamp)
          rescue StandardError => e
            # Error isolation - don't let one subscriber break others
            RubyLLM.logger.error("SwarmSDK: Subscription #{subscription.id} error: #{e.message}")
          end
        end
      end

      # Reset the collector (clears subscriptions for next execution)
      #
      # @return [void]
      def reset!
        Fiber[:log_subscriptions] = []
      end

      private

      # Get subscriptions from Fiber-local storage
      #
      # @return [Array<Subscription>] Current subscriptions
      def subscriptions
        Fiber[:log_subscriptions] ||= []
      end

      # Ensure event has a timestamp
      #
      # @param entry [Hash] Event entry
      # @return [Hash] Entry with timestamp
      def ensure_timestamp(entry)
        return entry if entry.key?(:timestamp)

        entry.merge(timestamp: Time.now.utc.iso8601(6))
      end
    end
  end
end
