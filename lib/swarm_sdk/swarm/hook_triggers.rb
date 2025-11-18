# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Hook triggering methods for swarm lifecycle events
    #
    # Extracted from Swarm to reduce class size and centralize hook execution logic.
    # These methods build contexts and execute hooks via the hook registry.
    module HookTriggers
      # Add a default callback for an event
      #
      # @param event [Symbol] Event type (:pre_tool_use, :post_tool_use, etc.)
      # @param matcher [Hash, nil] Optional matcher to filter events
      # @param priority [Integer] Callback priority (higher = later)
      # @param block [Proc] Hook implementation
      # @return [self]
      def add_default_callback(event, matcher: nil, priority: 0, &block)
        @hook_registry.add_default(event, matcher: matcher, priority: priority, &block)
        self
      end

      # Trigger swarm_stop hooks and check for reprompt
      #
      # @param result [Result] The execution result
      # @return [Hooks::Result, nil] Hook result (reprompt action if applicable)
      def trigger_swarm_stop(result)
        context = build_swarm_stop_context(result)
        executor = Hooks::Executor.new(@hook_registry, logger: RubyLLM.logger)
        executor.execute_safe(event: :swarm_stop, context: context, callbacks: [])
      rescue StandardError => e
        LogStream.emit_error(e, source: "hook_triggers", context: "swarm_stop", agent: @lead_agent)
        RubyLLM.logger.debug("SwarmSDK: Error in swarm_stop hook: #{e.message}")
        nil
      end

      # Trigger swarm_stop for final event emission (called in ensure block)
      #
      # @param result [Result, nil] Execution result
      # @param start_time [Time] Execution start time
      # @param logs [Array] Collected logs
      # @return [void]
      def trigger_swarm_stop_final(result, start_time, logs)
        result ||= Result.new(
          content: nil,
          agent: @lead_agent&.to_s || "unknown",
          logs: logs,
          duration: Time.now - start_time,
          error: StandardError.new("Unknown error"),
        )

        context = build_swarm_stop_context(result)
        executor = Hooks::Executor.new(@hook_registry, logger: RubyLLM.logger)
        executor.execute_safe(event: :swarm_stop, context: context, callbacks: [])
      rescue StandardError => e
        LogStream.emit_error(e, source: "hook_triggers", context: "swarm_stop_final", agent: @lead_agent)
        RubyLLM.logger.debug("SwarmSDK: Error in swarm_stop final emission: #{e.message}")
      end

      private

      # Build swarm_stop context (DRY - used by both trigger methods)
      #
      # @param result [Result] Execution result
      # @return [Hooks::Context] Hook context for swarm_stop event
      def build_swarm_stop_context(result)
        Hooks::Context.new(
          event: :swarm_stop,
          agent_name: @lead_agent.to_s,
          swarm: self,
          metadata: {
            swarm_name: @name,
            lead_agent: @lead_agent,
            last_agent: result.agent,
            content: result.content,
            success: result.success?,
            duration: result.duration,
            total_cost: result.total_cost,
            total_tokens: result.total_tokens,
            agents_involved: result.agents_involved,
            result: result,
            timestamp: Time.now.utc.iso8601,
          },
        )
      end

      # Trigger swarm_start hooks when swarm execution begins
      #
      # @param prompt [String] The user's task prompt
      # @return [Hooks::Result, nil] Result with stdout to append (if exit 0) or nil
      # @raise [Hooks::Error] If hook halts execution
      def trigger_swarm_start(prompt)
        context = Hooks::Context.new(
          event: :swarm_start,
          agent_name: @lead_agent.to_s,
          swarm: self,
          metadata: {
            swarm_name: @name,
            lead_agent: @lead_agent,
            prompt: prompt,
            timestamp: Time.now.utc.iso8601,
          },
        )

        executor = Hooks::Executor.new(@hook_registry, logger: RubyLLM.logger)
        result = executor.execute_safe(event: :swarm_start, context: context, callbacks: [])

        # Halt execution if hook requests it
        raise Hooks::Error, "Swarm start halted by hook: #{result.value}" if result.halt?

        # Return result so caller can check for replace (stdout injection)
        result
      rescue StandardError => e
        LogStream.emit_error(e, source: "hook_triggers", context: "swarm_start", agent: @lead_agent)
        RubyLLM.logger.debug("SwarmSDK: Error in swarm_start hook: #{e.message}")
        raise
      end

      # Trigger first_message hooks when first user message is sent
      #
      # @param prompt [String] The first user message
      # @return [void]
      # @raise [Hooks::Error] If hook halts execution
      def trigger_first_message(prompt)
        return if @hook_registry.get_defaults(:first_message).empty?

        context = Hooks::Context.new(
          event: :first_message,
          agent_name: @lead_agent.to_s,
          swarm: self,
          metadata: {
            swarm_name: @name,
            lead_agent: @lead_agent,
            prompt: prompt,
            timestamp: Time.now.utc.iso8601,
          },
        )

        executor = Hooks::Executor.new(@hook_registry, logger: RubyLLM.logger)
        result = executor.execute_safe(event: :first_message, context: context, callbacks: [])

        # Halt execution if hook requests it
        raise Hooks::Error, "First message halted by hook: #{result.value}" if result.halt?
      rescue StandardError => e
        LogStream.emit_error(e, source: "hook_triggers", context: "first_message", agent: @lead_agent)
        RubyLLM.logger.debug("SwarmSDK: Error in first_message hook: #{e.message}")
        raise
      end
    end
  end
end
