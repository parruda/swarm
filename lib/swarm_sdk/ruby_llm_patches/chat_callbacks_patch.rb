# frozen_string_literal: true

require "monitor"

# Extends RubyLLM::Chat with:
# - Multi-subscriber callbacks (allows multiple callbacks per event)
# - Subscription objects for unsubscribing
# - around_tool_execution hook for wrapping tool execution
# - around_llm_request hook for wrapping LLM API requests
# - Changed on_tool_result signature to pass (tool_call, result)
#
# Fork Reference: Commits d0912c7, a2a028d, 61cd510, 162189f

module RubyLLM
  class Chat
    # Represents an active subscription to a callback event
    class Subscription
      attr_reader :tag

      def initialize(callback_list, callback, monitor:, tag: nil)
        @callback_list = callback_list
        @callback = callback
        @monitor = monitor
        @tag = tag
        @active = true
      end

      def unsubscribe # rubocop:disable Naming/PredicateMethod
        @monitor.synchronize do
          return false unless @active

          @callback_list.delete(@callback)
          @active = false
        end
        true
      end

      def active?
        @monitor.synchronize do
          @active && @callback_list.include?(@callback)
        end
      end

      def inspect
        "#<#{self.class.name} tag=#{@tag.inspect} active=#{active?}>"
      end
    end

    # Module to prepend for multi-subscriber callbacks
    module MultiSubscriberCallbacks
      def initialize(**kwargs)
        super(**kwargs)

        # Replace single callback hash with multi-subscriber arrays
        @callbacks = {
          new_message: [],
          end_message: [],
          tool_call: [],
          tool_result: [],
        }
        @callback_monitor = Monitor.new

        # Initialize around hooks
        @around_tool_execution_hook = nil
        @around_llm_request_hook = nil

        # Keep @on for backward compatibility (read-only)
        @on = nil
      end

      # Subscribe to an event with the given block
      # Returns a Subscription that can be used to unsubscribe
      def subscribe(event, tag: nil, &block)
        @callback_monitor.synchronize do
          unless @callbacks.key?(event)
            raise ArgumentError, "Unknown event: #{event}. Valid events: #{@callbacks.keys.join(", ")}"
          end

          @callbacks[event] << block
          Subscription.new(@callbacks[event], block, monitor: @callback_monitor, tag: tag)
        end
      end

      # Subscribe to an event that automatically unsubscribes after firing once
      def once(event, tag: nil, &block)
        subscription = nil
        wrapper = lambda do |*args|
          subscription&.unsubscribe
          block.call(*args)
        end
        subscription = subscribe(event, tag: tag, &wrapper)
      end

      # Override callback registration methods to support multi-subscriber
      def on_new_message(&block)
        subscribe(:new_message, &block)
        self
      end

      def on_end_message(&block)
        subscribe(:end_message, &block)
        self
      end

      def on_tool_call(&block)
        subscribe(:tool_call, &block)
        self
      end

      def on_tool_result(&block)
        subscribe(:tool_result, &block)
        self
      end

      # Sets a hook to wrap tool execution with custom behavior
      #
      # @yield [ToolCall, Tool, Proc] Block called for each tool execution
      # @return [self] for chaining
      def around_tool_execution(&block)
        @around_tool_execution_hook = block
        self
      end

      # Sets a hook to wrap LLM API requests with custom behavior
      #
      # @yield [Array<Message>, Proc] Block called before each LLM request
      # @return [self] for chaining
      def around_llm_request(&block)
        @around_llm_request_hook = block
        self
      end

      # Clears all callbacks for the specified event, or all events if none specified
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

      # Returns the number of callbacks registered for the specified event
      def callback_count(event = nil)
        @callback_monitor.synchronize do
          if event
            @callbacks[event]&.size || 0
          else
            @callbacks.transform_values(&:size)
          end
        end
      end

      # Override complete to use emit() and support around_llm_request hook
      # Follows fork pattern: tool call handling wraps message addition
      def complete(&block)
        # Execute LLM request (potentially wrapped by around_llm_request hook)
        response = execute_llm_request(&block)

        emit(:new_message) unless block_given?

        if @schema && response.content.is_a?(String)
          begin
            response.content = JSON.parse(response.content)
          rescue JSON::ParserError
            # If parsing fails, keep content as string
          end
        end

        add_message(response)
        emit(:end_message, response)
        if response.tool_call?
          # For tool calls: add message, emit end_message, then handle tools
          handle_tool_calls(response, &block)
        else
          # For final responses: add message and emit end_message
          response
        end
      end

      private

      # Emit an event to all registered callbacks
      # Callbacks are called in FIFO order, errors are isolated
      def emit(event, *args)
        callbacks = @callback_monitor.synchronize { @callbacks[event]&.dup || [] }

        callbacks.each do |callback|
          callback.call(*args)
        rescue StandardError => e
          RubyLLM.logger.error("[RubyLLM] Callback error for #{event}: #{e.message}")
        end
      end

      # Execute LLM request, potentially wrapped by around_llm_request hook
      def execute_llm_request(&block)
        if @around_llm_request_hook
          @around_llm_request_hook.call(messages) do |prepared_messages = messages|
            perform_llm_request(prepared_messages, &block)
          end
        else
          perform_llm_request(messages, &block)
        end
      end

      # Perform the actual LLM request
      def perform_llm_request(messages_to_send, &block)
        @provider.complete(
          messages_to_send,
          tools: @tools,
          temperature: @temperature,
          model: @model,
          params: @params,
          headers: @headers,
          schema: @schema,
          thinking: @thinking,
          &wrap_streaming_block(&block)
        )
      rescue ArgumentError => e
        raise ArgumentError,
          "#{e.message} — provider #{@provider.class.name} does not support this parameter " \
            "(model: #{@model&.id || "unknown"})",
          e.backtrace
      end

      # Override wrap_streaming_block to use emit
      def wrap_streaming_block(&block)
        return unless block_given?

        emit(:new_message)

        proc do |chunk|
          block.call(chunk)
        end
      end

      # Override handle_tool_calls to use emit and support around_tool_execution hook
      def handle_tool_calls(response, &block)
        halt_result = nil

        response.tool_calls.each_value do |tool_call|
          emit(:new_message)
          emit(:tool_call, tool_call)

          result = execute_tool_with_hook(tool_call)

          # Emit tool_result with both tool_call and result (fork signature)
          emit(:tool_result, tool_call, result)

          tool_payload = result.is_a?(Tool::Halt) ? result.content : result
          content = content_like?(tool_payload) ? tool_payload : tool_payload.to_s
          message = add_message(role: :tool, content: content, tool_call_id: tool_call.id)
          emit(:end_message, message)

          halt_result = result if result.is_a?(Tool::Halt)
        end

        halt_result || complete(&block)
      end

      # Execute tool with around_tool_execution hook if set
      # Fork signature: hook receives (tool_call, tool_instance, execute_proc)
      # Note: tool_instance may be nil if tool is not found - the hook/execute_proc
      # should handle this case (will raise NoMethodError, caught by rescue)
      def execute_tool_with_hook(tool_call)
        tool_instance = tools[tool_call.name.to_sym]
        execute_proc = -> { tool_instance.call(tool_call.arguments) }

        if @around_tool_execution_hook
          @around_tool_execution_hook.call(tool_call, tool_instance, execute_proc)
        else
          execute_proc.call
        end
      rescue StandardError => e
        "Error: #{e.class}: #{e.message}"
      end
    end

    # Prepend the module to override methods
    prepend MultiSubscriberCallbacks
  end
end
