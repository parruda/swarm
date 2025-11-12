# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ExecuteWaitParameterTest < Minitest::Test
    def setup
      # Set fake API key to avoid RubyLLM configuration errors
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
      end

      @test_scratchpad = create_test_scratchpad
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
      end
      cleanup_test_scratchpads
    end

    # Test 1: Default behavior (wait: true implicitly) returns Result
    def test_execute_default_returns_result
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Default behavior - no wait parameter specified
      result = swarm.execute("Test prompt")

      assert_instance_of(Result, result, "Default execute should return Result")
      assert_predicate(result, :success?)
      assert_equal("Test response", result.content)
    end

    # Test 2: Explicit wait: true returns Result
    def test_execute_with_wait_true_returns_result
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Explicit wait: true
      result = swarm.execute("Test prompt", wait: true)

      assert_instance_of(Result, result, "execute(wait: true) should return Result")
      assert_predicate(result, :success?)
      assert_equal("Test response", result.content)
    end

    # Test 3: wait: false returns Async::Task
    def test_execute_with_wait_false_returns_async_task
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Non-blocking execution
      task = swarm.execute("Test prompt", wait: false)

      assert_instance_of(Async::Task, task, "execute(wait: false) should return Async::Task")

      # Can wait on the task to get result
      result = task.wait

      assert_instance_of(Result, result)
      assert_equal("Test response", result.content)
    end

    # Test 4: wait: false returns task that can be stopped
    #
    # Note: Testing actual cancellation in unit tests is difficult because
    # Ruby fibers use cooperative multitasking. task.stop queues an Async::Stop
    # exception, but it's only delivered when the fiber yields. If the fiber is
    # blocked in synchronous operations (sleep, sync I/O), cancellation is delayed.
    #
    # In real usage, Faraday with async mode yields during HTTP I/O, allowing
    # timely cancellation. This test verifies the task can be stopped without error.
    def test_execute_with_wait_false_can_be_stopped
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Start non-blocking execution
      task = swarm.execute("Test prompt", wait: false)

      # Verify task has stop method (it's an Async::Task)
      assert_respond_to(task, :stop, "Task should have stop method")

      # Stop the task (should not raise an error)
      task.stop

      # Wait should return (either Result or nil depending on timing)
      # In this test, timing may allow completion before stop takes effect
      task.wait
    end

    # Test 5: Logging works with wait: false
    def test_execute_with_wait_false_logs_events
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      events = []

      # Non-blocking execution with logging
      task = swarm.execute("Test prompt", wait: false) do |event|
        events << event
      end

      # Wait for completion
      result = task.wait

      # Verify result
      assert_instance_of(Result, result)
      assert_equal("Test response", result.content)

      # Verify events were emitted
      assert(events.any? { |e| e[:type] == "swarm_start" }, "Should emit swarm_start")
      assert(events.any? { |e| e[:type] == "agent_start" }, "Should emit agent_start")
      assert(events.any? { |e| e[:type] == "swarm_stop" }, "Should emit swarm_stop")
    end

    # Test 6: Fiber storage cleanup with wait: true
    def test_fiber_storage_cleanup_with_wait_true
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Execute with logging block (triggers fiber storage setup)
      swarm.execute("Test prompt", wait: true) { |_event| }

      # Fiber storage should be cleaned up after blocking execution
      assert_nil(Fiber[:execution_id], "Fiber[:execution_id] should be nil after wait: true")
      assert_nil(Fiber[:swarm_id], "Fiber[:swarm_id] should be nil after wait: true")
      assert_nil(Fiber[:parent_swarm_id], "Fiber[:parent_swarm_id] should be nil after wait: true")
    end

    # Test 7: Fiber storage with wait: false
    def test_fiber_storage_with_wait_false
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Execute with logging block and wait: false
      task = swarm.execute("Test prompt", wait: false) { |_event| }

      # Parent fiber storage is still set (not cleaned up until task completes)
      assert(Fiber[:execution_id], "Parent fiber storage remains set with wait: false")

      # Wait for completion - task's ensure block cleans up its own storage
      task.wait

      # Parent fiber storage is still set (we didn't call wait: true to clean it)
      # This is expected - only wait: true cleans parent storage
      assert(Fiber[:execution_id], "Parent fiber storage not automatically cleaned with wait: false")
    end

    # Test 8: Error handling with wait: false
    def test_error_handling_with_wait_false
      swarm = build_test_swarm

      # Stub error response
      stub_request(:post, %r{https?://.*/(v1/)?chat/completions})
        .to_return(status: 500, body: "Internal Server Error")

      # Non-blocking execution
      task = swarm.execute("Test prompt", wait: false)

      # Wait should still return a Result (with error)
      result = task.wait

      assert_instance_of(Result, result)
      refute_predicate(result, :success?)
      assert(result.error)
    end

    # Test 9: MCP cleanup happens in both modes
    def test_mcp_cleanup_happens_in_both_modes
      # This test verifies cleanup is called in the ensure block
      # Actual MCP client cleanup is tested elsewhere
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test"))

      # Track cleanup calls
      cleanup_called = false
      swarm.define_singleton_method(:cleanup) do
        cleanup_called = true
        super()
      end

      # Test wait: true
      swarm.execute("Test", wait: true)

      assert(cleanup_called, "cleanup should be called with wait: true")

      # Reset tracking
      cleanup_called = false

      # Test wait: false
      task = swarm.execute("Test", wait: false)
      task.wait

      assert(cleanup_called, "cleanup should be called with wait: false")
    end

    private

    def build_test_swarm
      swarm = Swarm.new(
        name: "Wait Parameter Test",
        scratchpad: @test_scratchpad,
      )

      agent_def = Agent::Definition.new(:test_agent, {
        description: "Test agent",
        model: "gpt-4",
        system_prompt: "You are a test agent",
        tools: [],
        assume_model_exists: true,
      })

      swarm.add_agent(agent_def)
      swarm.lead = :test_agent

      swarm
    end
  end
end
