# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class LogStreamTest < Minitest::Test
    # Mock emitter for testing
    class MockEmitter
      attr_reader :events

      def initialize
        @events = []
      end

      def emit(entry)
        @events << entry
      end
    end

    def setup
      LogStream.reset!
    end

    def teardown
      LogStream.reset!
    end

    def test_emit_with_no_emitter_does_not_crash
      # Should not raise error when no emitter configured
      assert_nil(LogStream.emit(type: "test", data: "value"))
    end

    def test_emit_with_emitter_forwards_event
      emitter = MockEmitter.new

      LogStream.emitter = emitter
      LogStream.emit(type: "test", agent: :backend, data: "value")

      assert_equal(1, emitter.events.size)
      event = emitter.events.first

      assert_equal("test", event[:type])
      assert_equal(:backend, event[:agent])
      assert_equal("value", event[:data])
    end

    def test_emit_adds_timestamp
      emitter = MockEmitter.new

      LogStream.emitter = emitter

      Time.now.utc.iso8601
      LogStream.emit(type: "test")
      Time.now.utc.iso8601

      event = emitter.events.first

      assert(event.key?(:timestamp))
      assert_instance_of(String, event[:timestamp])

      # Timestamp should be in ISO8601 format
      assert_match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, event[:timestamp])
    end

    def test_emit_compacts_nil_values
      emitter = MockEmitter.new

      LogStream.emitter = emitter
      LogStream.emit(type: "test", data: "value", empty: nil)

      event = emitter.events.first

      refute(event.key?(:empty), "Expected nil values to be removed")
      assert(event.key?(:data))
    end

    def test_reset_clears_emitter
      LogStream.emitter = Object.new

      assert_predicate(LogStream, :enabled?)

      LogStream.reset!

      refute_predicate(LogStream, :enabled?)
    end

    def test_enabled_returns_true_when_emitter_set
      refute_predicate(LogStream, :enabled?)

      LogStream.emitter = Object.new

      assert_predicate(LogStream, :enabled?)
    end

    def test_enabled_returns_false_when_no_emitter
      LogStream.reset!

      refute_predicate(LogStream, :enabled?)
    end

    def test_emitter_accessor_allows_reading
      emitter = Object.new
      LogStream.emitter = emitter

      assert_same(emitter, LogStream.emitter)
    end

    # Test thread safety: simulates concurrent requests in Puma
    # Each thread should have its own isolated emitter (no cross-thread contamination)
    def test_concurrent_threads_have_isolated_emitters
      thread_count = 5
      events_per_thread = 10

      # Create separate emitters for each thread
      emitters = thread_count.times.map { MockEmitter.new }

      # Simulate concurrent requests (like Puma thread pool)
      threads = thread_count.times.map do |i|
        Thread.new do
          # Each thread sets its own emitter (simulating swarm.execute with block)
          LogStream.emitter = emitters[i]

          # Verify emitter is correctly set for this thread
          assert_same(
            emitters[i],
            LogStream.emitter,
            "Thread #{i} should have its own emitter",
          )

          # Emit multiple events
          events_per_thread.times do |j|
            LogStream.emit(
              type: "test_event",
              thread_id: i,
              event_number: j,
              message: "Thread #{i}, Event #{j}",
            )

            # Small random sleep to increase chance of interleaving
            sleep(rand * 0.01)
          end

          # Cleanup (simulating swarm.execute ensure block)
          LogStream.reset!
        end
      end

      # Wait for all threads to complete
      threads.each(&:join)

      # After threads complete, verify each emitter received exactly its own events
      thread_count.times do |i|
        emitter = emitters[i]

        assert_equal(
          events_per_thread,
          emitter.events.size,
          "Thread #{i}'s emitter should have received exactly #{events_per_thread} events",
        )

        # Verify all events belong to this thread
        emitter.events.each_with_index do |event, j|
          assert_equal(
            i,
            event[:thread_id],
            "Event #{j} in thread #{i}'s emitter should have thread_id=#{i}",
          )
          assert_equal(
            j,
            event[:event_number],
            "Event #{j} in thread #{i}'s emitter should have event_number=#{j}",
          )
        end

        # Verify no cross-thread contamination
        # (emitter should only have events from its own thread)
        thread_ids = emitter.events.map { |e| e[:thread_id] }.uniq

        assert_equal(
          [i],
          thread_ids,
          "Emitter #{i} should only have events from thread #{i}, but had: #{thread_ids}",
        )
      end
    end

    # Test that child fibers inherit parent's emitter
    def test_child_fibers_inherit_emitter
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      # Emit from parent fiber
      LogStream.emit(type: "parent_event", source: "parent")

      # Create child fiber and emit
      Async do
        # Child fiber should inherit parent's emitter
        assert_same(
          emitter,
          LogStream.emitter,
          "Child fiber should inherit parent's emitter",
        )

        LogStream.emit(type: "child_event", source: "child")
      end.wait

      # Both events should be in the same emitter
      assert_equal(2, emitter.events.size)
      assert_equal("parent", emitter.events[0][:source])
      assert_equal("child", emitter.events[1][:source])
    end

    # emit_error helper tests

    def test_emit_error_creates_internal_error_event
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("Test error message")
      LogStream.emit_error(error, source: "test_source", context: "test_context")

      assert_equal(1, emitter.events.size)
      event = emitter.events.first

      assert_equal("internal_error", event[:type])
      assert_equal("test_source", event[:source])
      assert_equal("test_context", event[:context])
      assert_equal("StandardError", event[:error_class])
      assert_equal("Test error message", event[:error_message])
    end

    def test_emit_error_includes_backtrace_first_5_lines
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      # Create error with backtrace
      error = begin
        raise StandardError, "Error with backtrace"
      rescue StandardError => e
        e
      end

      LogStream.emit_error(error, source: "test", context: "test")

      event = emitter.events.first
      backtrace = event[:backtrace]

      assert_instance_of(Array, backtrace)
      assert_operator(backtrace.size, :<=, 5)
      assert_match(/log_stream_test\.rb/, backtrace.first)
    end

    def test_emit_error_handles_nil_backtrace
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("No backtrace")
      # Error without backtrace has nil backtrace
      LogStream.emit_error(error, source: "test", context: "test")

      event = emitter.events.first

      refute(event.key?(:backtrace), "Should not include backtrace key when nil")
    end

    def test_emit_error_includes_optional_agent_parameter
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("Agent error")
      LogStream.emit_error(error, source: "hooks", context: "pre_tool", agent: :backend)

      event = emitter.events.first

      assert_equal(:backend, event[:agent])
    end

    def test_emit_error_without_agent_omits_agent_field
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("No agent error")
      LogStream.emit_error(error, source: "test", context: "test")

      event = emitter.events.first

      refute(event.key?(:agent), "Should not include agent key when nil")
    end

    def test_emit_error_supports_additional_metadata
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("Error with metadata")
      LogStream.emit_error(
        error,
        source: "tool",
        context: "execution",
        agent: :frontend,
        tool_name: "Read",
        file_path: "/test/file.rb",
      )

      event = emitter.events.first

      assert_equal("Read", event[:tool_name])
      assert_equal("/test/file.rb", event[:file_path])
    end

    def test_emit_error_includes_timestamp
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("Timestamped error")
      LogStream.emit_error(error, source: "test", context: "test")

      event = emitter.events.first

      assert(event.key?(:timestamp))
      assert_match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, event[:timestamp])
    end

    def test_emit_error_is_safe_when_no_emitter
      # Should not raise when no emitter is configured
      LogStream.reset!

      error = StandardError.new("Error without emitter")
      result = LogStream.emit_error(error, source: "test", context: "test")

      # Should return nil without error
      assert_nil(result)
    end

    def test_emit_error_is_defensive_against_failing_emitter
      # Mock emitter that raises on emit
      failing_emitter = Object.new
      def failing_emitter.emit(_entry)
        raise "Emitter failure!"
      end

      LogStream.emitter = failing_emitter

      error = StandardError.new("Original error")

      # Should NOT raise, even if emitter fails
      result = LogStream.emit_error(error, source: "test", context: "test")

      # Returns nil on failure (defensive)
      assert_nil(result)
    end

    def test_emit_error_handles_various_exception_types
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      # Test with ArgumentError
      arg_error = ArgumentError.new("Invalid argument")
      LogStream.emit_error(arg_error, source: "parser", context: "validation")

      # Test with RuntimeError
      runtime_error = RuntimeError.new("Runtime issue")
      LogStream.emit_error(runtime_error, source: "executor", context: "execution")

      # Test with custom error class
      custom_error = begin
        raise TypeError, "Type mismatch"
      rescue StandardError => e
        e
      end
      LogStream.emit_error(custom_error, source: "type_checker", context: "check")

      assert_equal(3, emitter.events.size)

      assert_equal("ArgumentError", emitter.events[0][:error_class])
      assert_equal("RuntimeError", emitter.events[1][:error_class])
      assert_equal("TypeError", emitter.events[2][:error_class])
    end

    def test_emit_error_preserves_execution_context_from_fiber_storage
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      # Set execution context in Fiber storage
      Fiber[:execution_id] = "exec-123"
      Fiber[:swarm_id] = "swarm-456"
      Fiber[:parent_swarm_id] = "parent-789"

      error = StandardError.new("Context test")
      LogStream.emit_error(error, source: "test", context: "test")

      event = emitter.events.first

      assert_equal("exec-123", event[:execution_id])
      assert_equal("swarm-456", event[:swarm_id])
      assert_equal("parent-789", event[:parent_swarm_id])
    ensure
      Fiber[:execution_id] = nil
      Fiber[:swarm_id] = nil
      Fiber[:parent_swarm_id] = nil
    end

    def test_emit_error_with_string_agent_name
      emitter = MockEmitter.new
      LogStream.emitter = emitter

      error = StandardError.new("String agent name")
      LogStream.emit_error(error, source: "test", context: "test", agent: "backend")

      event = emitter.events.first

      assert_equal("backend", event[:agent])
    end
  end
end
