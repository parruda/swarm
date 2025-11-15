# frozen_string_literal: true

require "monitor"

module SwarmSDK
  module Agent
    module ChatHelpers
      # Minimal event emitter that mirrors RubyLLM::Chat's callback pattern
      #
      # Provides multi-subscriber support for events like tool_call, tool_result,
      # new_message, end_message. This is thread-safe and supports unsubscription.
      module EventEmitter
        # Represents an active subscription to a callback event.
        # Returned by {#subscribe} and can be used to unsubscribe later.
        class Subscription
          attr_reader :tag

          def initialize(callback_list, callback, monitor:, tag: nil)
            @callback_list = callback_list
            @callback = callback
            @monitor = monitor
            @tag = tag
            @active = true
          end

          # Removes this subscription from the callback list.
          # @return [Boolean] true if successfully unsubscribed, false if already inactive
          def unsubscribe # rubocop:disable Naming/PredicateMethod
            @monitor.synchronize do
              return false unless @active

              @callback_list.delete(@callback)
              @active = false
            end
            true
          end

          # Checks if this subscription is still active.
          # @return [Boolean] true if still subscribed
          def active?
            @monitor.synchronize do
              @active && @callback_list.include?(@callback)
            end
          end

          def inspect
            "#<#{self.class.name} tag=#{@tag.inspect} active=#{active?}>"
          end
        end

        # Initialize the event emitter system
        #
        # Sets up @callbacks hash and @callback_monitor for thread safety.
        # Must be called in Chat#initialize.
        #
        # @return [void]
        def initialize_event_emitter
          @callbacks = {
            new_message: [],
            end_message: [],
            tool_call: [],
            tool_result: [],
          }
          @callback_monitor = Monitor.new
        end

        # Subscribes to an event with the given block.
        # Returns a {Subscription} that can be used to unsubscribe.
        #
        # @param event [Symbol] The event to subscribe to
        # @param tag [String, nil] Optional tag for debugging/identification
        # @yield The block to call when the event fires
        # @return [Subscription] An object that can be used to unsubscribe
        # @raise [ArgumentError] if event is not recognized
        def subscribe(event, tag: nil, &block)
          @callback_monitor.synchronize do
            unless @callbacks.key?(event)
              raise ArgumentError, "Unknown event: #{event}. Valid events: #{@callbacks.keys.join(", ")}"
            end

            @callbacks[event] << block
            Subscription.new(@callbacks[event], block, monitor: @callback_monitor, tag: tag)
          end
        end

        # Subscribes to an event that automatically unsubscribes after firing once.
        #
        # @param event [Symbol] The event to subscribe to
        # @param tag [String, nil] Optional tag for debugging/identification
        # @yield The block to call when the event fires (once)
        # @return [Subscription] An object that can be used to unsubscribe before it fires
        def once(event, tag: nil, &block)
          subscription = nil
          wrapper = lambda do |*args|
            subscription&.unsubscribe
            block.call(*args)
          end
          subscription = subscribe(event, tag: tag, &wrapper)
        end

        # Registers a callback for when a new message starts being generated.
        # Multiple callbacks can be registered and all will fire in registration order.
        #
        # @yield Block called when a new message starts
        # @return [self] for chaining
        def on_new_message(&block)
          subscribe(:new_message, &block)
          self
        end

        # Registers a callback for when a message is complete.
        # Multiple callbacks can be registered and all will fire in registration order.
        #
        # @yield [Message] Block called with the completed message
        # @return [self] for chaining
        def on_end_message(&block)
          subscribe(:end_message, &block)
          self
        end

        # Registers a callback for when a tool is called.
        # Multiple callbacks can be registered and all will fire in registration order.
        #
        # @yield [ToolCall] Block called with the tool call object
        # @return [self] for chaining
        def on_tool_call(&block)
          subscribe(:tool_call, &block)
          self
        end

        # Registers a callback for when a tool returns a result.
        # Multiple callbacks can be registered and all will fire in registration order.
        #
        # @yield [Object] Block called with the tool result
        # @return [self] for chaining
        def on_tool_result(&block)
          subscribe(:tool_result, &block)
          self
        end

        # Clears all callbacks for the specified event, or all events if none specified.
        #
        # @param event [Symbol, nil] The event to clear callbacks for, or nil for all events
        # @return [self] for chaining
        def clear_callbacks(event = nil)
          @callback_monitor.synchronize do
            if event
              @callbacks[event]&.clear
            else
              @callbacks.each_value(&:clear)
            end
          end
          self
        end

        # Returns the number of callbacks registered for the specified event.
        #
        # @param event [Symbol, nil] The event to count callbacks for, or nil for all events
        # @return [Integer, Hash] Count for specific event, or hash of counts for all events
        def callback_count(event = nil)
          @callback_monitor.synchronize do
            if event
              @callbacks[event]&.size || 0
            else
              @callbacks.transform_values(&:size)
            end
          end
        end

        private

        # Emits an event to all registered subscribers.
        # Callbacks are executed in registration order (FIFO).
        # Errors in callbacks are isolated - one failing callback doesn't prevent others from running.
        #
        # @param event [Symbol] The event to emit
        # @param args [Array] Arguments to pass to each callback
        # @return [void]
        def emit(event, *args)
          # Snapshot callbacks under lock (fast operation)
          callbacks = @callback_monitor.synchronize { @callbacks[event]&.dup || [] }

          # Execute callbacks outside lock (safe, non-blocking)
          callbacks.each do |callback|
            callback.call(*args)
          rescue StandardError => e
            handle_callback_error(event, callback, e)
          end
        end

        # Hook for custom error handling when a callback raises an exception.
        # Override this method in Chat to customize error behavior.
        #
        # @param event [Symbol] The event that was being emitted
        # @param callback [Proc] The callback that raised the error
        # @param error [StandardError] The error that was raised
        # @return [void]
        def handle_callback_error(event, _callback, error)
          warn("[SwarmSDK] Callback error in #{event}: #{error.class} - #{error.message}")
        end
      end
    end
  end
end
