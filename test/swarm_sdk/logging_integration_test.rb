# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class LoggingIntegrationTest < Minitest::Test
    include LLMMockHelper

    def setup
      # Reset logging state before each test (in case previous test failed)
      begin
        LogStream.reset!
      rescue StandardError
        nil
      end

      begin
        LogCollector.reset!
      rescue StandardError
        nil
      end

      # Set dummy API key for tests
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      # Also configure RubyLLM directly to avoid caching issues
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
      end
    end

    def teardown
      # Use begin/ensure to guarantee cleanup even if reset! raises
      begin
        LogStream.reset!
      rescue StandardError
        nil
      end

      begin
        LogCollector.reset!
      rescue StandardError
        nil
      end

      WebMock.reset!
      ENV["OPENAI_API_KEY"] = @original_api_key
      # Reset RubyLLM configuration
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
      end
    end

    def test_logging_flow_from_swarm_execute
      swarm = Swarm.new(name: "Test Swarm", scratchpad: Tools::Stores::ScratchpadStorage.new)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead developer",
        model: "gpt-5",
        system_prompt: "You are a lead developer",
        directory: ".",
      ))

      swarm.lead = :lead

      # Mock LLM response
      stub_llm_request(mock_llm_response(content: "Test response"))

      logs = []
      result = swarm.execute("test prompt") do |log_entry|
        logs << log_entry
      end

      assert_predicate(result, :success?)
      refute_empty(logs, "Expected logs to be collected")

      # Verify log structure
      logs.each do |log|
        assert_instance_of(Hash, log)
        assert(log.key?(:type), "Log entry missing :type field")
        assert(log.key?(:timestamp), "Log entry missing :timestamp field")
      end

      # Verify we have expected log types
      log_types = logs.map { |log| log[:type] }.uniq

      assert_includes(log_types, "user_prompt", "Expected user_request log")
      assert_includes(log_types, "agent_stop", "Expected agent_stop log")
    end

    def test_logstream_and_logcollector_integration
      events = []

      # Register callback
      LogCollector.subscribe { |event| events << event }

      # Set collector as emitter
      LogStream.emitter = LogCollector

      # Emit events
      LogStream.emit(type: "test1", data: "value1")
      LogStream.emit(type: "test2", data: "value2")

      assert_equal(2, events.size)
      assert_equal("test1", events[0][:type])
      assert_equal("test2", events[1][:type])
    end

    def test_agent_context_tracks_delegations_in_logging
      context = Agent::Context.new(
        name: :coordinator,
        swarm_id: "test_swarm",
        delegation_tools: ["DelegateToBackend", "DelegateToFrontend"],
      )

      # Track a delegation
      context.track_delegation(call_id: "call_123", target: "DelegateToBackend")

      assert(context.delegation?(call_id: "call_123"))
      assert_equal("DelegateToBackend", context.delegation_target(call_id: "call_123"))

      # Clear delegation
      context.clear_delegation(call_id: "call_123")

      refute(context.delegation?(call_id: "call_123"))
    end

    def test_context_warnings_tracked_in_agent_context
      context = Agent::Context.new(name: :backend, swarm_id: "test_swarm")

      # First hit returns true
      assert(context.hit_warning_threshold?(80))

      # Already hit
      assert(context.warning_threshold_hit?(80))

      # Second hit returns false
      refute(context.hit_warning_threshold?(80))
    end

    def test_logging_includes_agent_information
      swarm = Swarm.new(name: "Test Swarm", scratchpad: Tools::Stores::ScratchpadStorage.new)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-5",
        system_prompt: "You are a backend developer",
        directory: ".",
      ))

      swarm.lead = :backend

      stub_llm_request(mock_llm_response(content: "Backend response"))

      logs = []
      result = swarm.execute("Build API") do |log_entry|
        logs << log_entry
      end

      assert_predicate(result, :success?)

      # All logs should include agent information (except swarm-level events)
      logs.each do |log|
        # Swarm-level events (swarm_start, swarm_stop) don't have :agent field
        # They have :lead_agent and :last_agent instead
        next if ["swarm_start", "swarm_stop"].include?(log[:type])

        assert(log.key?(:agent), "Log entry missing :agent field: #{log.inspect}")
        assert_equal(:backend, log[:agent])
      end
    end

    def test_logging_works_without_block
      swarm = Swarm.new(name: "Test Swarm", scratchpad: Tools::Stores::ScratchpadStorage.new)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      stub_llm_request(mock_llm_response(content: "Response"))

      # Execute without logging block
      result = swarm.execute("test")

      assert_predicate(result, :success?)
      assert_empty(result.logs, "Expected no logs when no block provided")
    end
  end
end
