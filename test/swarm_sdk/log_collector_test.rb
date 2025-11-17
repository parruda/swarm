# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class LogCollectorTest < Minitest::Test
    def setup
      LogCollector.reset!
    end

    def teardown
      LogCollector.reset!
    end

    # Basic subscription tests

    def test_subscribe_registers_callback
      events = []
      LogCollector.subscribe { |event| events << event }

      LogCollector.emit(type: "test", data: "value")

      assert_equal(1, events.size)
      assert_equal("test", events.first[:type])
    end

    def test_subscribe_returns_subscription_id
      sub_id = LogCollector.subscribe { |event| }

      assert_kind_of(String, sub_id)
      refute_empty(sub_id)
    end

    def test_subscribe_registers_multiple_callbacks
      events1 = []
      events2 = []

      LogCollector.subscribe { |event| events1 << event }
      LogCollector.subscribe { |event| events2 << event }

      LogCollector.emit(type: "test", data: "value")

      assert_equal(1, events1.size)
      assert_equal(1, events2.size)
      assert_equal(events1.first, events2.first)
    end

    def test_emit_with_no_subscriptions_does_not_crash
      # Should not raise error when no subscriptions registered
      LogCollector.emit(type: "test")

      # Should not crash and subscription_count should be 0
      assert_equal(0, LogCollector.subscription_count)
    end

    def test_reset_clears_subscriptions
      events = []
      LogCollector.subscribe { |event| events << event }

      assert_equal(1, LogCollector.subscription_count)

      LogCollector.reset!

      assert_equal(0, LogCollector.subscription_count)

      # After reset, should be able to register new subscriptions
      LogCollector.subscribe { |event| events << event }
      LogCollector.emit(type: "test")

      # Only new subscription should be called
      assert_equal(1, events.size)
    end

    def test_subscriptions_receive_entry_with_timestamp
      received = nil
      LogCollector.subscribe { |event| received = event }

      entry = { type: "test", agent: :backend, data: "value" }
      LogCollector.emit(entry)

      # Should include all original fields
      assert_equal("test", received[:type])
      assert_equal(:backend, received[:agent])
      assert_equal("value", received[:data])

      # Should have auto-added timestamp with microsecond precision
      assert(received.key?(:timestamp), "Missing timestamp")
      assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/, received[:timestamp])
    end

    def test_existing_timestamps_are_preserved
      received = nil
      LogCollector.subscribe { |event| received = event }

      custom_timestamp = "2025-01-01T12:00:00Z"
      entry = { type: "test", timestamp: custom_timestamp }
      LogCollector.emit(entry)

      # Should preserve the custom timestamp
      assert_equal(custom_timestamp, received[:timestamp])
    end

    # Filtering tests

    def test_filter_by_agent_symbol
      events = []
      LogCollector.subscribe(filter: { agent: :backend }) { |event| events << event }

      LogCollector.emit(type: "test", agent: :backend)
      LogCollector.emit(type: "test", agent: :frontend)

      assert_equal(1, events.size)
      assert_equal(:backend, events.first[:agent])
    end

    def test_filter_by_agent_string
      events = []
      LogCollector.subscribe(filter: { agent: "backend" }) { |event| events << event }

      LogCollector.emit(type: "test", agent: :backend)

      assert_equal(1, events.size)
    end

    def test_filter_by_type_string
      events = []
      LogCollector.subscribe(filter: { type: "tool_call" }) { |event| events << event }

      LogCollector.emit(type: "tool_call", agent: :backend)
      LogCollector.emit(type: "tool_result", agent: :backend)

      assert_equal(1, events.size)
      assert_equal("tool_call", events.first[:type])
    end

    def test_filter_by_type_array
      events = []
      LogCollector.subscribe(filter: { type: ["tool_call", "tool_result"] }) { |event| events << event }

      LogCollector.emit(type: "tool_call", agent: :backend)
      LogCollector.emit(type: "tool_result", agent: :backend)
      LogCollector.emit(type: "agent_stop", agent: :backend)

      assert_equal(2, events.size)
      assert_includes(events.map { |e| e[:type] }, "tool_call")
      assert_includes(events.map { |e| e[:type] }, "tool_result")
    end

    def test_filter_by_type_regex
      events = []
      LogCollector.subscribe(filter: { type: /^tool_/ }) { |event| events << event }

      LogCollector.emit(type: "tool_call", agent: :backend)
      LogCollector.emit(type: "tool_result", agent: :backend)
      LogCollector.emit(type: "agent_stop", agent: :backend)

      assert_equal(2, events.size)
    end

    def test_filter_by_multiple_agents_array
      events = []
      LogCollector.subscribe(filter: { agent: [:backend, :frontend] }) { |event| events << event }

      LogCollector.emit(type: "test", agent: :backend)
      LogCollector.emit(type: "test", agent: :frontend)
      LogCollector.emit(type: "test", agent: :database)

      assert_equal(2, events.size)
    end

    def test_filter_with_multiple_criteria_and_logic
      events = []
      LogCollector.subscribe(filter: { agent: :backend, type: "tool_call" }) { |event| events << event }

      LogCollector.emit(type: "tool_call", agent: :backend)
      LogCollector.emit(type: "tool_result", agent: :backend)
      LogCollector.emit(type: "tool_call", agent: :frontend)

      # Only events matching BOTH criteria should be received
      assert_equal(1, events.size)
      assert_equal(:backend, events.first[:agent])
      assert_equal("tool_call", events.first[:type])
    end

    def test_filter_by_swarm_id
      events = []
      LogCollector.subscribe(filter: { swarm_id: "swarm_123" }) { |event| events << event }

      LogCollector.emit(type: "test", swarm_id: "swarm_123")
      LogCollector.emit(type: "test", swarm_id: "swarm_456")

      assert_equal(1, events.size)
      assert_equal("swarm_123", events.first[:swarm_id])
    end

    def test_empty_filter_matches_all_events
      events = []
      LogCollector.subscribe(filter: {}) { |event| events << event }

      LogCollector.emit(type: "test1", agent: :backend)
      LogCollector.emit(type: "test2", agent: :frontend)
      LogCollector.emit(type: "test3", swarm_id: "any")

      assert_equal(3, events.size)
    end

    def test_filter_with_proc_custom_matcher
      events = []
      LogCollector.subscribe(filter: { agent: ->(val) { val.to_s.length > 5 } }) { |event| events << event }

      LogCollector.emit(type: "test", agent: :backend) # length 7 - matches
      LogCollector.emit(type: "test", agent: :api) # length 3 - doesn't match

      assert_equal(1, events.size)
      assert_equal(:backend, events.first[:agent])
    end

    # Unsubscribe tests

    def test_unsubscribe_removes_subscription
      events = []
      sub_id = LogCollector.subscribe { |event| events << event }

      assert_equal(1, LogCollector.subscription_count)

      removed = LogCollector.unsubscribe(sub_id)

      assert(removed)
      assert_equal(0, LogCollector.subscription_count)

      # Should not receive events after unsubscribe
      LogCollector.emit(type: "test")

      assert_empty(events)
    end

    def test_unsubscribe_returns_nil_for_nonexistent_id
      removed = LogCollector.unsubscribe("nonexistent_id")

      assert_nil(removed)
    end

    def test_unsubscribe_only_removes_specified_subscription
      events1 = []
      events2 = []

      sub_id1 = LogCollector.subscribe { |event| events1 << event }
      LogCollector.subscribe { |event| events2 << event }

      LogCollector.unsubscribe(sub_id1)

      LogCollector.emit(type: "test")

      assert_empty(events1)
      assert_equal(1, events2.size)
    end

    def test_clear_subscriptions_removes_all
      LogCollector.subscribe { |event| }
      LogCollector.subscribe { |event| }
      LogCollector.subscribe { |event| }

      assert_equal(3, LogCollector.subscription_count)

      LogCollector.clear_subscriptions

      assert_equal(0, LogCollector.subscription_count)
    end

    # Error isolation tests

    def test_error_in_subscriber_does_not_break_others
      events = []

      # Mock RubyLLM.logger to capture error
      mock_logger = Minitest::Mock.new
      mock_logger.expect(:error, nil, [String])

      RubyLLM.stub(:logger, mock_logger) do
        LogCollector.subscribe { |_event| raise StandardError, "Subscriber error" }
        LogCollector.subscribe { |event| events << event }

        LogCollector.emit(type: "test")
      end

      # Second subscriber should still receive event
      assert_equal(1, events.size)
      mock_logger.verify
    end

    def test_multiple_subscriber_errors_are_isolated
      events = []

      mock_logger = Minitest::Mock.new
      2.times { mock_logger.expect(:error, nil, [String]) }

      RubyLLM.stub(:logger, mock_logger) do
        LogCollector.subscribe { |_event| raise StandardError, "Error 1" }
        LogCollector.subscribe { |_event| raise StandardError, "Error 2" }
        LogCollector.subscribe { |event| events << event }

        LogCollector.emit(type: "test")
      end

      assert_equal(1, events.size)
      mock_logger.verify
    end

    # Subscription object tests

    def test_subscription_matches_empty_filter
      sub = LogCollector::Subscription.new(filter: {}) { |_| }

      assert(sub.matches?({ type: "anything", agent: :any }))
    end

    def test_subscription_matches_exact_value
      sub = LogCollector::Subscription.new(filter: { type: "test" }) { |_| }

      assert(sub.matches?({ type: "test", agent: :backend }))
      refute(sub.matches?({ type: "other", agent: :backend }))
    end

    def test_subscription_matches_array_values
      sub = LogCollector::Subscription.new(filter: { type: ["a", "b", "c"] }) { |_| }

      assert(sub.matches?({ type: "a" }))
      assert(sub.matches?({ type: "b" }))
      assert(sub.matches?({ type: "c" }))
      refute(sub.matches?({ type: "d" }))
    end

    def test_subscription_matches_regex
      sub = LogCollector::Subscription.new(filter: { type: /^agent_/ }) { |_| }

      assert(sub.matches?({ type: "agent_start" }))
      assert(sub.matches?({ type: "agent_stop" }))
      refute(sub.matches?({ type: "tool_call" }))
    end

    def test_subscription_normalizes_string_keys_to_symbols
      sub = LogCollector::Subscription.new(filter: { "type" => "test" }) { |_| }

      assert(sub.matches?({ type: "test" }))
    end

    def test_subscription_handles_symbol_string_mismatch
      sub = LogCollector::Subscription.new(filter: { agent: :backend }) { |_| }

      # Should match symbol value
      assert(sub.matches?({ agent: :backend }))
      # Should also match string value (coercion)
      assert(sub.matches?({ agent: "backend" }))
    end

    def test_subscription_id_is_unique
      sub1 = LogCollector::Subscription.new(filter: {}) { |_| }
      sub2 = LogCollector::Subscription.new(filter: {}) { |_| }

      refute_equal(sub1.id, sub2.id)
    end

    # Integration tests

    def test_observer_pattern_cross_agent_monitoring
      backend_events = []
      all_events = []

      # Subscribe to all events
      LogCollector.subscribe { |event| all_events << event }

      # Subscribe only to backend agent
      LogCollector.subscribe(filter: { agent: :backend }) { |event| backend_events << event }

      # Simulate multi-agent execution
      LogCollector.emit(type: "agent_start", agent: :backend)
      LogCollector.emit(type: "tool_call", agent: :backend, tool: "Read")
      LogCollector.emit(type: "agent_start", agent: :frontend)
      LogCollector.emit(type: "agent_stop", agent: :backend)
      LogCollector.emit(type: "agent_stop", agent: :frontend)

      # All events subscriber should receive everything
      assert_equal(5, all_events.size)

      # Backend observer should only receive backend events
      assert_equal(3, backend_events.size)
      backend_events.each do |event|
        assert_equal(:backend, event[:agent])
      end
    end
  end
end
