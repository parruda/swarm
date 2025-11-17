# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Patterns
    class AgentObserverTest < Minitest::Test
      def setup
        LogCollector.reset!
      end

      def teardown
        LogCollector.reset!
      end

      # Initialization tests

      def test_initializes_with_target_agent
        observer = AgentObserver.new(target: :backend)

        assert_equal(:backend, observer.target_agent)
        assert_empty(observer.observations)
        refute_predicate(observer, :observing?)
      end

      def test_initializes_with_event_types_filter
        observer = AgentObserver.new(
          target: :backend,
          event_types: ["tool_call", "tool_result"],
        )

        assert_equal(:backend, observer.target_agent)
        refute_predicate(observer, :observing?)
      end

      def test_initializes_with_on_event_callback
        callback_called = false
        observer = AgentObserver.new(
          target: :backend,
          on_event: ->(_e) { callback_called = true },
        )

        refute(callback_called)
        refute_predicate(observer, :observing?)
      end

      # Start/Stop tests

      def test_start_begins_observation
        observer = AgentObserver.new(target: :backend)

        refute_predicate(observer, :observing?)

        observer.start

        assert_predicate(observer, :observing?)
      end

      def test_stop_ends_observation
        observer = AgentObserver.new(target: :backend)
        observer.start

        assert_predicate(observer, :observing?)

        observer.stop

        refute_predicate(observer, :observing?)
      end

      def test_start_clears_previous_observations
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Read")

        assert_equal(1, observer.observations.size)

        observer.stop
        observer.start

        assert_empty(observer.observations)
      end

      def test_start_is_idempotent
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "test", agent: :backend)

        assert_equal(1, observer.observations.size)

        # Second start should be no-op
        observer.start

        # Should not have cleared observations
        assert_equal(1, observer.observations.size)

        # Should still be the same subscription
        assert_equal(1, LogCollector.subscription_count)
      end

      def test_stop_is_idempotent
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "test", agent: :backend)

        observer.stop
        observer.stop

        # Second stop should be no-op, no errors
        refute_predicate(observer, :observing?)

        # Observations should be preserved after stop
        assert_equal(1, observer.observations.size)
      end

      # Event collection tests

      def test_collects_events_for_target_agent
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Read")
        LogCollector.emit(type: "tool_result", agent: :backend, tool_name: "Read", result: "content")

        assert_equal(2, observer.observations.size)
        assert_equal("tool_call", observer.observations[0][:type])
        assert_equal("tool_result", observer.observations[1][:type])
      ensure
        observer.stop
      end

      def test_ignores_events_from_other_agents
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Read")
        LogCollector.emit(type: "tool_call", agent: :frontend, tool_name: "Write")
        LogCollector.emit(type: "tool_call", agent: :database, tool_name: "Query")

        assert_equal(1, observer.observations.size)
        assert_equal(:backend, observer.observations[0][:agent])
      ensure
        observer.stop
      end

      def test_filters_by_event_type
        observer = AgentObserver.new(
          target: :backend,
          event_types: ["tool_call"],
        )
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Read")
        LogCollector.emit(type: "tool_result", agent: :backend, result: "content")
        LogCollector.emit(type: "agent_stop", agent: :backend, content: "Done")

        assert_equal(1, observer.observations.size)
        assert_equal("tool_call", observer.observations[0][:type])
      ensure
        observer.stop
      end

      def test_filters_multiple_event_types
        observer = AgentObserver.new(
          target: :backend,
          event_types: ["tool_call", "tool_result"],
        )
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Read")
        LogCollector.emit(type: "tool_result", agent: :backend, result: "content")
        LogCollector.emit(type: "agent_stop", agent: :backend, content: "Done")

        assert_equal(2, observer.observations.size)
      ensure
        observer.stop
      end

      def test_adds_observed_at_timestamp
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "test", agent: :backend)

        assert(observer.observations.first.key?(:observed_at))
        assert_instance_of(Time, observer.observations.first[:observed_at])
      ensure
        observer.stop
      end

      def test_preserves_original_event_data
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(
          type: "tool_call",
          agent: :backend,
          tool_name: "Read",
          arguments: { path: "/foo/bar" },
        )

        event = observer.observations.first

        assert_equal("tool_call", event[:type])
        assert_equal(:backend, event[:agent])
        assert_equal("Read", event[:tool_name])
        assert_equal({ path: "/foo/bar" }, event[:arguments])
      ensure
        observer.stop
      end

      # Callback tests

      def test_on_event_callback_is_called
        events_received = []
        observer = AgentObserver.new(
          target: :backend,
          on_event: ->(e) { events_received << e },
        )
        observer.start

        LogCollector.emit(type: "test", agent: :backend)

        assert_equal(1, events_received.size)
        assert_equal("test", events_received.first[:type])
      ensure
        observer.stop
      end

      def test_on_event_callback_receives_original_event
        received_event = nil
        observer = AgentObserver.new(
          target: :backend,
          on_event: ->(e) { received_event = e },
        )
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Bash")

        # Callback receives original event (without :observed_at added by observation)
        assert_equal("tool_call", received_event[:type])
        assert_equal(:backend, received_event[:agent])
        assert_equal("Bash", received_event[:tool_name])
      ensure
        observer.stop
      end

      def test_observation_continues_if_callback_raises
        observer = AgentObserver.new(
          target: :backend,
          on_event: ->(_e) { raise StandardError, "Callback error" },
        )

        # Mock logger to suppress error output
        mock_logger = Minitest::Mock.new
        mock_logger.expect(:error, nil, [String])

        RubyLLM.stub(:logger, mock_logger) do
          observer.start

          # This will trigger the callback error, but observation should continue
          LogCollector.emit(type: "test", agent: :backend)
        end

        # Event should still be recorded despite callback error
        assert_equal(1, observer.observations.size)
      ensure
        observer.stop
      end

      # Summary tests

      def test_summary_includes_target
        observer = AgentObserver.new(target: :backend)

        summary = observer.summary

        assert_equal(:backend, summary[:target])
      end

      def test_summary_includes_started_at
        observer = AgentObserver.new(target: :backend)

        summary = observer.summary

        assert_nil(summary[:started_at])

        observer.start

        summary = observer.summary

        refute_nil(summary[:started_at])
        assert_instance_of(Time, summary[:started_at])
      ensure
        observer.stop
      end

      def test_summary_includes_duration
        observer = AgentObserver.new(target: :backend)

        summary = observer.summary

        assert_equal(0, summary[:duration_seconds])

        observer.start
        sleep(0.1) # Short delay to measure duration

        summary = observer.summary

        assert_operator(summary[:duration_seconds], :>, 0)
      ensure
        observer.stop
      end

      def test_summary_includes_total_events
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "test1", agent: :backend)
        LogCollector.emit(type: "test2", agent: :backend)
        LogCollector.emit(type: "test3", agent: :backend)

        summary = observer.summary

        assert_equal(3, summary[:total_events])
      ensure
        observer.stop
      end

      def test_summary_includes_event_breakdown
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend)
        LogCollector.emit(type: "tool_call", agent: :backend)
        LogCollector.emit(type: "tool_result", agent: :backend)
        LogCollector.emit(type: "agent_stop", agent: :backend)

        summary = observer.summary

        assert_equal({ "tool_call" => 2, "tool_result" => 1, "agent_stop" => 1 }, summary[:event_breakdown])
      ensure
        observer.stop
      end

      def test_summary_includes_tool_calls
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Read")
        LogCollector.emit(type: "tool_call", agent: :backend, tool_name: "Write")
        LogCollector.emit(type: "agent_stop", agent: :backend)

        summary = observer.summary

        assert_equal(["Read", "Write"], summary[:tool_calls])
      ensure
        observer.stop
      end

      def test_summary_includes_errors
        observer = AgentObserver.new(target: :backend)
        observer.start

        error_event = {
          type: "internal_error",
          agent: :backend,
          message: "Something went wrong",
        }
        LogCollector.emit(error_event)

        summary = observer.summary

        assert_equal(1, summary[:errors].size)
        assert_equal("internal_error", summary[:errors].first[:type])
      ensure
        observer.stop
      end

      # to_llm_context tests

      def test_to_llm_context_formats_tool_calls
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(
          type: "tool_call",
          agent: :backend,
          tool_name: "Read",
          arguments: { path: "/foo" },
        )

        context = observer.to_llm_context

        assert_includes(context, "Called Read with:")
        assert_includes(context, '"/foo"')
      ensure
        observer.stop
      end

      def test_to_llm_context_formats_tool_results
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(
          type: "tool_result",
          agent: :backend,
          tool_name: "Read",
          result: "File content here",
        )

        context = observer.to_llm_context

        assert_includes(context, "Read returned: File content here")
      ensure
        observer.stop
      end

      def test_to_llm_context_formats_agent_stop
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(
          type: "agent_stop",
          agent: :backend,
          content: "Task completed",
        )

        context = observer.to_llm_context

        assert_includes(context, "Final response: Task completed")
      ensure
        observer.stop
      end

      def test_to_llm_context_truncates_long_content
        observer = AgentObserver.new(target: :backend)
        observer.start

        long_content = "x" * 500
        LogCollector.emit(
          type: "tool_result",
          agent: :backend,
          tool_name: "Read",
          result: long_content,
        )

        context = observer.to_llm_context

        assert_includes(context, "...")
        assert_operator(context.length, :<, 500)
      ensure
        observer.stop
      end

      def test_to_llm_context_handles_nil_values
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(
          type: "tool_result",
          agent: :backend,
          tool_name: "Bash",
          result: nil,
        )

        context = observer.to_llm_context

        # Should not raise, should handle nil gracefully
        refute_nil(context)
        assert_includes(context, "Bash returned:")
      ensure
        observer.stop
      end

      # clear_observations tests

      def test_clear_observations_removes_all_observations
        observer = AgentObserver.new(target: :backend)
        observer.start

        LogCollector.emit(type: "test", agent: :backend)

        assert_equal(1, observer.observations.size)

        observer.clear_observations

        assert_empty(observer.observations)
      ensure
        observer.stop
      end

      # observe block tests

      def test_observe_block_automatically_starts_and_stops
        observer = AgentObserver.new(target: :backend)

        refute_predicate(observer, :observing?)

        observer.observe do
          assert_predicate(observer, :observing?)
          LogCollector.emit(type: "test", agent: :backend)
        end

        refute_predicate(observer, :observing?)
        assert_equal(1, observer.observations.size)
      end

      def test_observe_block_returns_block_result
        observer = AgentObserver.new(target: :backend)

        result = observer.observe do
          "block result"
        end

        assert_equal("block result", result)
      end

      def test_observe_block_stops_on_exception
        observer = AgentObserver.new(target: :backend)

        assert_raises(StandardError) do
          observer.observe do
            raise StandardError, "Block error"
          end
        end

        # Should still stop observing despite exception
        refute_predicate(observer, :observing?)
      end

      # Integration tests

      def test_multiple_observers_can_watch_same_agent
        observer1 = AgentObserver.new(target: :backend)
        observer2 = AgentObserver.new(target: :backend)

        observer1.start
        observer2.start

        LogCollector.emit(type: "test", agent: :backend)

        assert_equal(1, observer1.observations.size)
        assert_equal(1, observer2.observations.size)
      ensure
        observer1.stop
        observer2.stop
      end

      def test_observers_can_watch_different_agents
        backend_observer = AgentObserver.new(target: :backend)
        frontend_observer = AgentObserver.new(target: :frontend)

        backend_observer.start
        frontend_observer.start

        LogCollector.emit(type: "test", agent: :backend)
        LogCollector.emit(type: "test", agent: :frontend)
        LogCollector.emit(type: "test", agent: :backend)

        assert_equal(2, backend_observer.observations.size)
        assert_equal(1, frontend_observer.observations.size)
      ensure
        backend_observer.stop
        frontend_observer.stop
      end
    end
  end
end
