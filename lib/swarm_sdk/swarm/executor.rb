# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Handles swarm execution orchestration
    #
    # Extracted from Swarm#execute to reduce complexity and eliminate code duplication.
    # The core execution loop, error handling, and cleanup logic are unified here.
    class Executor
      def initialize(swarm)
        @swarm = swarm
      end

      # Execute the swarm with a prompt
      #
      # @param prompt [String] User prompt
      # @param wait [Boolean] Block until completion (true) or return task (false)
      # @param logs [Array] Log collection array
      # @param has_logging [Boolean] Whether logging is enabled
      # @param original_fiber_storage [Hash] Original Fiber storage values to restore
      # @return [Async::Task] The execution task
      def run(prompt, wait:, logs:, has_logging:, original_fiber_storage:)
        @original_fiber_storage = original_fiber_storage
        if wait
          run_blocking(prompt, logs: logs, has_logging: has_logging)
        else
          run_async(prompt, logs: logs, has_logging: has_logging)
        end
      end

      private

      # Blocking execution using Sync
      def run_blocking(prompt, logs:, has_logging:)
        Sync do |task|
          execute_in_task(prompt, logs: logs, has_logging: has_logging) do |lead, current_prompt|
            task.async(finished: false) { lead.ask(current_prompt) }.wait
          end
        end
      ensure
        # Restore original fiber storage (preserves parent context for nested swarms)
        restore_fiber_storage
      end

      # Non-blocking execution using parent async task
      def run_async(prompt, logs:, has_logging:)
        parent = Async::Task.current
        raise ConfigurationError, "wait: false requires an async context. Use Sync { swarm.execute(..., wait: false) }" unless parent

        parent.async(finished: false) do
          execute_in_task(prompt, logs: logs, has_logging: has_logging) do |lead, current_prompt|
            Async(finished: false) { lead.ask(current_prompt) }.wait
          end
        end
      end

      # Core execution logic (unified, no duplication)
      #
      # @param prompt [String] Initial prompt
      # @param logs [Array] Log collection
      # @param has_logging [Boolean] Whether logging is enabled
      # @yield [lead, current_prompt] Block to execute LLM call
      # @return [Result] Execution result
      def execute_in_task(prompt, logs:, has_logging:, &block)
        start_time = Time.now
        result = nil
        swarm_stop_triggered = false
        current_prompt = prompt

        begin
          # Notify plugins that swarm is starting
          PluginRegistry.emit_event(:on_swarm_started, swarm: @swarm)

          result = execution_loop(current_prompt, logs, start_time, &block)
          swarm_stop_triggered = true
        rescue ConfigurationError, AgentNotFoundError
          # Re-raise configuration errors - these should be fixed, not caught
          raise
        rescue TypeError => e
          result = handle_type_error(e, logs, start_time)
        rescue StandardError => e
          result = handle_standard_error(e, logs, start_time)
        ensure
          # Notify plugins that swarm is stopping (called even on error)
          PluginRegistry.emit_event(:on_swarm_stopped, swarm: @swarm)

          cleanup_after_execution(result, start_time, logs, swarm_stop_triggered, has_logging)
        end

        result
      end

      # Main execution loop with reprompting support
      def execution_loop(initial_prompt, logs, start_time)
        current_prompt = initial_prompt

        loop do
          lead = @swarm.agents[@swarm.lead_agent]
          response = yield(lead, current_prompt)

          # Check if swarm was finished by a hook (finish_swarm)
          if response.is_a?(Hash) && response[:__finish_swarm__]
            result = build_result(response[:message], logs, start_time)
            @swarm.trigger_swarm_stop(result)
            return result
          end

          result = build_result(response.content, logs, start_time)

          # Trigger swarm_stop hooks (for reprompt check and event emission)
          hook_result = @swarm.trigger_swarm_stop(result)

          # Check if hook requests reprompting
          if hook_result&.reprompt?
            current_prompt = hook_result.value
            # Continue loop with new prompt
          else
            # Exit loop - execution complete
            return result
          end
        end
      end

      # Build a Result object
      def build_result(content, logs, start_time)
        Result.new(
          content: content,
          agent: @swarm.lead_agent.to_s,
          logs: logs,
          duration: Time.now - start_time,
        )
      end

      # Handle TypeError (e.g., "String does not have #dig method")
      def handle_type_error(error, logs, start_time)
        if error.message.include?("does not have #dig method")
          agent_definition = @swarm.agent_definitions[@swarm.lead_agent]
          error_msg = if agent_definition.base_url
            "LLM API request failed: The proxy/server at '#{agent_definition.base_url}' returned an invalid response. " \
              "This usually means the proxy is unreachable, requires authentication, or returned an error in non-JSON format. " \
              "Original error: #{error.message}"
          else
            "LLM API request failed with unexpected response format. Original error: #{error.message}"
          end

          Result.new(
            content: nil,
            agent: @swarm.lead_agent.to_s,
            error: LLMError.new(error_msg),
            logs: logs,
            duration: Time.now - start_time,
          )
        else
          Result.new(
            content: nil,
            agent: @swarm.lead_agent.to_s,
            error: error,
            logs: logs,
            duration: Time.now - start_time,
          )
        end
      end

      # Handle StandardError
      def handle_standard_error(error, logs, start_time)
        Result.new(
          content: nil,
          agent: @swarm.lead_agent&.to_s || "unknown",
          error: error,
          logs: logs,
          duration: Time.now - start_time,
        )
      end

      # Cleanup after execution (ensure block logic)
      def cleanup_after_execution(result, start_time, logs, swarm_stop_triggered, has_logging)
        # Trigger swarm_stop if not already triggered (handles error cases)
        unless swarm_stop_triggered
          @swarm.trigger_swarm_stop_final(result, start_time, logs)
        end

        # Cleanup MCP clients after execution
        @swarm.cleanup

        # Restore original Fiber storage (preserves parent context for nested swarms)
        restore_fiber_storage

        # Reset logging state for next execution if we set it up
        reset_logging if has_logging
      end

      # Restore Fiber-local storage to original values (preserves parent context)
      def restore_fiber_storage
        Fiber[:execution_id] = @original_fiber_storage[:execution_id]
        Fiber[:swarm_id] = @original_fiber_storage[:swarm_id]
        Fiber[:parent_swarm_id] = @original_fiber_storage[:parent_swarm_id]
      end

      # Reset logging state
      def reset_logging
        LogCollector.reset!
        LogStream.reset!
      end
    end
  end
end
