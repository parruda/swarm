# frozen_string_literal: true

module SwarmSDK
  # LogStream provides a module-level singleton for emitting log events.
  #
  # This allows any component (tools, providers, agents) to emit structured
  # log events without needing references to logger instances.
  #
  # ## Usage
  #
  #   # Emit an event from anywhere in the SDK
  #   LogStream.emit(
  #     type: "user_prompt",
  #     agent: :backend,
  #     model: "claude-sonnet-4",
  #     message_count: 5
  #   )
  #
  # ## Thread Safety
  #
  # LogStream is thread-safe and fiber-safe:
  # - Uses Fiber storage for per-request isolation in multi-threaded servers (Puma, Sidekiq)
  # - Each thread/request has its own emitter instance
  # - Child fibers inherit the emitter from their parent fiber
  # - No cross-thread contamination of log events
  #
  # Usage pattern:
  # 1. Set emitter BEFORE starting Async execution
  # 2. During Async execution, only emit() (reads emitter)
  # 3. Each event includes agent context for identification
  #
  # ## Testing
  #
  #   # Inject a test emitter
  #   LogStream.emitter = TestEmitter.new
  #   # ... run tests ...
  #   LogStream.reset!
  #
  module LogStream
    class << self
      # Emit a log event
      #
      # Adds timestamp and forwards to the registered emitter.
      # Auto-injects execution_id, swarm_id, and parent_swarm_id from Fiber storage.
      # Explicit values in data override auto-injected ones.
      #
      # @param data [Hash] Event data (type, agent, and event-specific fields)
      # @return [void]
      def emit(**data)
        emitter = Fiber[:log_stream_emitter]
        return unless emitter

        # Auto-inject execution context from Fiber storage
        # Explicit values in data override auto-injected ones
        auto_injected = {
          execution_id: Fiber[:execution_id],
          swarm_id: Fiber[:swarm_id],
          parent_swarm_id: Fiber[:parent_swarm_id],
        }.compact

        entry = auto_injected.merge(data).merge(timestamp: Time.now.utc.iso8601(6)).compact

        emitter.emit(entry)
      end

      # Set the emitter (for dependency injection in tests)
      #
      # Stores emitter in Fiber storage for thread-safe, per-request isolation.
      #
      # @param emitter [#emit] Object responding to emit(Hash)
      # @return [void]
      def emitter=(emitter)
        Fiber[:log_stream_emitter] = emitter
      end

      # Get the current emitter
      #
      # @return [#emit, nil] Current emitter or nil if not set
      def emitter
        Fiber[:log_stream_emitter]
      end

      # Reset the emitter (for test cleanup)
      #
      # @return [void]
      def reset!
        Fiber[:log_stream_emitter] = nil
      end

      # Check if logging is enabled
      #
      # @return [Boolean] true if an emitter is configured
      def enabled?
        !Fiber[:log_stream_emitter].nil?
      end

      # Emit an internal error event
      #
      # Provides consistent error event emission for all internal errors.
      # These are errors that occur during execution but are handled gracefully
      # (with fallback behavior) rather than causing failures.
      #
      # @param error [Exception] The caught exception
      # @param source [String] Source module/class (e.g., "hook_triggers", "context_compactor")
      # @param context [String] Specific operation context (e.g., "swarm_stop", "summarization")
      # @param agent [Symbol, String, nil] Agent name if applicable
      # @param metadata [Hash] Additional context data
      # @return [void]
      def emit_error(error, source:, context:, agent: nil, **metadata)
        emit(
          type: "internal_error",
          source: source,
          context: context,
          agent: agent,
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace&.first(5),
          **metadata,
        )
      rescue StandardError
        # Absolute fallback - if emit_error itself fails, don't break execution
        # This should never happen, but we must be defensive
        nil
      end
    end
  end
end
