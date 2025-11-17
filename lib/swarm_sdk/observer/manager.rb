# frozen_string_literal: true

module SwarmSDK
  module Observer
    # Manages observer agent executions
    #
    # Handles:
    # - Event subscription via LogCollector
    # - Spawning async tasks for observer agents
    # - Self-consumption protection (observers don't trigger themselves)
    # - Task lifecycle and cleanup
    #
    # @example
    #   manager = Observer::Manager.new(swarm)
    #   manager.add_config(profiler_config)
    #   manager.setup
    #   # ... main execution happens ...
    #   manager.wait_for_completion
    #   manager.cleanup
    class Manager
      # Initialize manager with swarm reference
      #
      # @param swarm [Swarm] Parent swarm instance
      def initialize(swarm)
        @swarm = swarm
        @configs = []
        @subscription_ids = []
        @barrier = nil
        @task_ids = {}
      end

      # Add an observer configuration
      #
      # @param config [Observer::Config] Observer configuration
      # @return [void]
      def add_config(config)
        @configs << config
      end

      # Setup event subscriptions for all observer configs
      #
      # Creates LogCollector subscriptions for each event type, filtered by type.
      # Must be called after setup_logging() in Swarm.execute().
      #
      # @return [void]
      def setup
        @barrier = Async::Barrier.new

        @configs.each do |config|
          config.event_handlers.each do |event_type, handler|
            sub_id = LogCollector.subscribe(filter: { type: event_type.to_s }) do |event|
              handle_event(config, handler, event)
            end
            @subscription_ids << sub_id
          end
        end
      end

      # Wait for all observer tasks to complete
      #
      # Uses Async::Barrier.wait to wait for all spawned tasks.
      # Handles errors gracefully without stopping other observers.
      #
      # @return [void]
      def wait_for_completion
        return unless @barrier

        # Wait for all tasks, handling errors gracefully
        # Barrier.wait re-raises first exception by default, so we use block form
        @barrier.wait do |task|
          task.wait
        rescue StandardError => error
          # Log but don't stop waiting for other observers
          RubyLLM.logger.error("Observer task failed: #{error.message}")
        end
      end

      # Cleanup all subscriptions
      #
      # Unsubscribes from LogCollector to prevent memory leaks.
      # Called by Executor.cleanup_after_execution.
      #
      # @return [void]
      def cleanup
        @subscription_ids.each { |id| LogCollector.unsubscribe(id) }
        @subscription_ids.clear
      end

      private

      # Handle an incoming event
      #
      # Checks self-consumption protection, calls handler block,
      # and spawns execution if handler returns a prompt.
      #
      # @param config [Observer::Config] Observer configuration
      # @param handler [Proc] Event handler block
      # @param event [Hash] Event data
      # @return [void]
      def handle_event(config, handler, event)
        # CRITICAL: Prevent self-consumption - observer must not consume its own events
        # This prevents infinite loops where an observer triggers itself
        return if event[:agent] == config.agent_name

        prompt = handler.call(event)
        return unless prompt # nil means skip

        spawn_execution(config, prompt, event)
      end

      # Spawn an async task for observer execution
      #
      # Creates a child async task via barrier for the observer agent.
      # Sets observer-specific Fiber context.
      #
      # @param config [Observer::Config] Observer configuration
      # @param prompt [String] Prompt to send to observer agent
      # @param trigger_event [Hash] Event that triggered this execution
      # @return [void]
      def spawn_execution(config, prompt, trigger_event)
        @barrier.async do
          # Set observer-specific context in child fiber
          # No need to restore - child fiber dies when task completes
          Fiber[:swarm_id] = "#{Fiber[:swarm_id]}/observer:#{config.agent_name}"

          execute_observer_agent(config, prompt, trigger_event)
        end
      end

      # Execute the observer agent with the prompt
      #
      # Creates an isolated chat instance and sends the prompt.
      # Emits lifecycle events (start, complete, error).
      #
      # @param config [Observer::Config] Observer configuration
      # @param prompt [String] Prompt to execute
      # @param trigger_event [Hash] Event that triggered this execution
      # @return [RubyLLM::Message, nil] Response or nil on error
      def execute_observer_agent(config, prompt, trigger_event)
        agent_chat = create_isolated_chat(config.agent_name)

        start_time = Time.now
        emit_observer_start(config, trigger_event)

        result = agent_chat.ask(prompt)

        emit_observer_complete(config, trigger_event, result, Time.now - start_time)
        result
      rescue StandardError => e
        emit_observer_error(config, trigger_event, e)
        nil
      end

      # Create an isolated chat instance for the observer agent
      #
      # Uses AgentInitializer to create a fully configured agent chat
      # without delegation tools (observers don't delegate).
      #
      # @param agent_name [Symbol] Name of the observer agent
      # @return [Agent::Chat] Isolated chat instance
      def create_isolated_chat(agent_name)
        initializer = Swarm::AgentInitializer.new(@swarm)
        initializer.initialize_isolated_agent(agent_name)
      end

      # Emit observer_agent_start event
      #
      # @param config [Observer::Config] Observer configuration
      # @param trigger_event [Hash] Triggering event
      # @return [void]
      def emit_observer_start(config, trigger_event)
        return unless LogStream.emitter

        LogStream.emit(
          type: "observer_agent_start",
          agent: config.agent_name,
          trigger_event: trigger_event[:type],
          trigger_timestamp: trigger_event[:timestamp],
          task_id: generate_task_id(config),
          timestamp: Time.now.utc.iso8601,
        )
      end

      # Emit observer_agent_complete event
      #
      # @param config [Observer::Config] Observer configuration
      # @param trigger_event [Hash] Triggering event
      # @param result [RubyLLM::Message] Agent response
      # @param duration [Float] Execution duration in seconds
      # @return [void]
      def emit_observer_complete(config, trigger_event, result, duration)
        return unless LogStream.emitter

        LogStream.emit(
          type: "observer_agent_complete",
          agent: config.agent_name,
          trigger_event: trigger_event[:type],
          task_id: generate_task_id(config),
          duration: duration.round(3),
          success: true,
          timestamp: Time.now.utc.iso8601,
        )
      end

      # Emit observer_agent_error event
      #
      # @param config [Observer::Config] Observer configuration
      # @param trigger_event [Hash] Triggering event
      # @param error [StandardError] Error that occurred
      # @return [void]
      def emit_observer_error(config, trigger_event, error)
        return unless LogStream.emitter

        LogStream.emit(
          type: "observer_agent_error",
          agent: config.agent_name,
          trigger_event: trigger_event[:type],
          task_id: generate_task_id(config),
          error: error.message,
          backtrace: error.backtrace&.first(5),
          timestamp: Time.now.utc.iso8601,
        )
      end

      # Generate a unique task ID for an observer
      #
      # Cached per observer agent name for correlation.
      #
      # @param config [Observer::Config] Observer configuration
      # @return [String] Task ID
      def generate_task_id(config)
        @task_ids[config.agent_name] ||= "observer_#{SecureRandom.hex(6)}"
      end
    end
  end
end
