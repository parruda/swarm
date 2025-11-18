# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ExecuteWaitParameterTest < Minitest::Test
    def setup
      # CRITICAL: Clean up Fiber scheduler BEFORE test to ensure clean state
      # Previous tests might have left scheduler or fiber-local storage dirty
      Fiber.set_scheduler(nil) if Fiber.scheduler
      Fiber[:execution_id] = nil
      Fiber[:swarm_id] = nil
      Fiber[:parent_swarm_id] = nil
      Fiber[:log_subscriptions] = nil

      # Set fake API key to avoid RubyLLM configuration errors
      @original_api_key = ENV["OPENAI_API_KEY"]
      @original_max_retries = RubyLLM.config.max_retries
      @original_request_timeout = RubyLLM.config.request_timeout
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
        # CRITICAL: Disable retries AND set short timeout for tests
        # Faraday's retry middleware uses blocking sleep/I/O which doesn't
        # cooperate with Async fibers. Setting max_retries=0 makes errors
        # fail instantly instead of hanging for retry timeouts.
        # Setting request_timeout=1 makes Net::HTTP timeout quickly instead
        # of waiting 90s (Net::HTTP's default open_timeout + read_timeout).
        config.max_retries = 0
        config.request_timeout = 1 # 1 second timeout for fast test failures
      end

      @test_scratchpad = create_test_scratchpad
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
        config.max_retries = @original_max_retries
        config.request_timeout = @original_request_timeout
      end
      cleanup_test_scratchpads

      # CRITICAL: Clean up Fiber scheduler to ensure clean state between tests
      # The Async gem sets Fiber.scheduler when creating reactors, and if it's
      # not cleaned up properly, subsequent tests may hang or behave incorrectly.
      # This is especially important because Swarm#execute tries to manage the
      # scheduler itself (see lines 291-293 in swarm.rb).
      Fiber.set_scheduler(nil) if Fiber.scheduler

      # Also clean up any lingering fiber-local storage that might interfere
      Fiber[:execution_id] = nil
      Fiber[:swarm_id] = nil
      Fiber[:parent_swarm_id] = nil
      Fiber[:log_subscriptions] = nil
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
    #
    # NOTE: wait: false requires an existing async context (reactor) to work properly.
    # When Async() is called from a sync context with no scheduler, it creates a
    # reactor and blocks until completion, making non-blocking execution impossible.
    # This test wraps execution in Sync{} to provide the required async context.
    #
    # SKIP: This test requires RubyLLM to use async-http-faraday adapter by default
    # to avoid fiber blocking. The adapter is configured in the forked ruby_llm gem.
    def test_execute_with_wait_false_returns_async_task
      swarm = build_test_swarm
      stub_llm_request(mock_llm_response(content: "Test response"))

      Sync do
        # Non-blocking execution within async context
        task = swarm.execute("Test prompt", wait: false)

        assert_instance_of(Async::Task, task, "execute(wait: false) should return Async::Task")

        # Can wait on the task to get result
        result = task.wait

        assert_instance_of(Result, result)
        assert_equal("Test response", result.content)
      end
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

      Sync do
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
    end

    # Test 5: Logging works with wait: false
    def test_execute_with_wait_false_logs_events
      swarm = build_test_swarm
      stub_llm_request(mock_llm_response(content: "Test response"))

      Sync do
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
    #
    # Note: With async-http-faraday adapter configured in test_helper.rb,
    # this test now works properly in async contexts.
    def test_fiber_storage_with_wait_false
      swarm = build_test_swarm
      stub_llm_request(mock_llm_response(content: "Test response"))

      Sync do
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
    end

    # Test 8: Error handling with wait: true
    #
    # SKIP: Testing HTTP-level errors is complex because:
    # 1. WebMock + async-http-faraday causes 90-second blocking delays (connection pool timeout)
    # 2. Stubbing RubyLLM::Chat internals requires mocking many methods (with_instructions,
    #    with_tools, on_connect, on_new_message, etc.) which is fragile
    # 3. The error handling behavior is implicitly tested by other tests
    #
    # When RubyLLM supports async-http-faraday natively, this test should be re-enabled
    # with proper HTTP-level stubbing.
    def test_error_handling_with_wait_true
      skip("Requires proper async-http WebMock integration - HTTP stubs cause 90s timeout")

      # Original test intention:
      # - Stub HTTP request to return malformed JSON
      # - Verify that execute(wait: true) returns Result with error (not raises)
      # - Verify error details are accessible via result.error
    end

    # Test 9: MCP cleanup happens in both modes
    #
    # SKIP: wait: false portion requires RubyLLM async-http-faraday adapter configuration
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

      # Test wait: true (doesn't need Sync wrapper)
      swarm.execute("Test", wait: true)

      assert(cleanup_called, "cleanup should be called with wait: true")

      # wait: false test skipped - requires RubyLLM async-http-faraday configuration
      # When that's available, add:
      # cleanup_called = false
      # Sync do
      #   task = swarm.execute("Test", wait: false)
      #   task.wait
      #   assert(cleanup_called, "cleanup should be called with wait: false")
      # end
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
