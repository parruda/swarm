# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ExecutionTrackingTest < Minitest::Test
    include LLMMockHelper

    def setup
      # Reset logging state before each test
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
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
      end
    end

    def teardown
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
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
      end
    end

    # Test Case 1: Execution ID Uniqueness
    def test_execution_id_uniqueness
      swarm = build_test_swarm

      # Mock LLM responses
      stub_llm_request(mock_llm_response(content: "Response 1"))

      # First execution
      execution_ids_1 = []
      result1 = swarm.execute("Task 1") do |event|
        execution_ids_1 << event[:execution_id] if event[:execution_id]
      end

      assert_predicate(result1, :success?)

      # Mock second LLM response
      stub_llm_request(mock_llm_response(content: "Response 2"))

      # Second execution
      execution_ids_2 = []
      result2 = swarm.execute("Task 2") do |event|
        execution_ids_2 << event[:execution_id] if event[:execution_id]
      end

      assert_predicate(result2, :success?)

      # All events in result1 should have same execution_id
      assert_equal(1, execution_ids_1.uniq.size, "First execution should have consistent execution_id")

      # All events in result2 should have same execution_id
      assert_equal(1, execution_ids_2.uniq.size, "Second execution should have consistent execution_id")

      # result1 and result2 should have DIFFERENT execution_ids
      refute_equal(
        execution_ids_1.first,
        execution_ids_2.first,
        "Different executions should have different execution_ids",
      )
    end

    # Test Case 2: Nested Swarm Inheritance (Workflow)
    def test_node_workflow_execution_id_inheritance
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Build System"
          agents:
            planner:
              model: gpt-4o-mini
              description: "You are a planner"
              directory: "."
            coder:
              model: gpt-4o-mini
              description: "You are a coder"
              directory: "."
          nodes:
            planning:
              agents:
                - agent: planner
            implementation:
              agents:
                - agent: coder
              dependencies: [planning]
          start_node: planning
      YAML

      orchestrator = SwarmSDK.load(yaml, base_dir: ".")

      # Mock LLM responses for both nodes
      stub_llm_request(mock_llm_response(content: "Planning done"))
      stub_llm_request(mock_llm_response(content: "Implementation done"))

      execution_ids = []
      result = orchestrator.execute("Build system") do |event|
        execution_ids << event[:execution_id] if event[:execution_id]
      end

      assert_predicate(result, :success?)

      # All node events and mini-swarm events share same execution_id
      assert_equal(
        1,
        execution_ids.uniq.size,
        "All events in workflow should share same execution_id",
      )

      # Verify execution_id format
      assert_match(
        /^exec_workflow_[a-f0-9]{16}$/,
        execution_ids.first,
        "Workflow execution_id should match expected format",
      )
    end

    # Test Case 3: All Events Have swarm_id
    def test_all_events_have_swarm_id
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      event_types_without_swarm_id = []

      swarm.execute("Task") do |event|
        # Only memory_embedding_generated may have nil swarm_id (storage operation)
        next if event[:type] == "memory_embedding_generated"

        if event[:swarm_id].nil?
          event_types_without_swarm_id << event[:type]
        end
      end

      assert_empty(
        event_types_without_swarm_id,
        "These events missing swarm_id: #{event_types_without_swarm_id.join(", ")}",
      )
    end

    # Test Case 4: All Events Have execution_id
    def test_all_events_have_execution_id
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      event_types_without_execution_id = []

      swarm.execute("Task") do |event|
        # Only memory_embedding_generated may have nil execution_id (storage operation)
        next if event[:type] == "memory_embedding_generated"

        if event[:execution_id].nil?
          event_types_without_execution_id << event[:type]
        end
      end

      assert_empty(
        event_types_without_execution_id,
        "These events missing execution_id: #{event_types_without_execution_id.join(", ")}",
      )
    end

    # Test Case 5: Instance Isolation
    def test_instance_isolation
      # Use different names to ensure different swarm_ids
      swarm1 = build_test_swarm_with_name("Test Swarm 1")
      swarm2 = build_test_swarm_with_name("Test Swarm 2")

      execution_ids_1 = []
      execution_ids_2 = []

      # Mock LLM responses for both swarms
      stub_llm_request(mock_llm_response(content: "Response 1"))
      stub_llm_request(mock_llm_response(content: "Response 2"))

      threads = []
      threads << Thread.new do
        swarm1.execute("Task 1") { |e| execution_ids_1 << e[:execution_id] if e[:execution_id] }
      end

      threads << Thread.new do
        swarm2.execute("Task 2") { |e| execution_ids_2 << e[:execution_id] if e[:execution_id] }
      end

      threads.each(&:join)

      # Each swarm should have consistent execution_id
      assert_equal(1, execution_ids_1.uniq.size, "Swarm 1 should have consistent execution_id")
      assert_equal(1, execution_ids_2.uniq.size, "Swarm 2 should have consistent execution_id")

      # Different swarms should have different execution_ids
      refute_equal(
        execution_ids_1.first,
        execution_ids_2.first,
        "Different swarm instances should have different execution_ids",
      )
    end

    # Test Case 6: Fiber Storage Propagation
    def test_fiber_storage_propagation
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      execution_id = nil
      swarm_id = nil

      swarm.execute("Test") do |event|
        if event[:type] == "swarm_start"
          execution_id = event[:execution_id]
          swarm_id = event[:swarm_id]
        end

        # All events should have same IDs
        if event[:execution_id]
          assert_equal(
            execution_id,
            event[:execution_id],
            "Event #{event[:type]} has different execution_id",
          )
        end

        if event[:swarm_id]
          assert_equal(
            swarm_id,
            event[:swarm_id],
            "Event #{event[:type]} has different swarm_id",
          )
        end
      end

      refute_nil(execution_id, "Should have captured execution_id")
      refute_nil(swarm_id, "Should have captured swarm_id")
    end

    # Test Case 7: Context Ownership in Nested Swarms (Critical!)
    def test_context_ownership_in_nested_swarms
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Dev Team"
          agents:
            worker:
              model: gpt-4o-mini
              description: "You are a worker"
              directory: "."
          nodes:
            node1:
              agents:
                - agent: worker
            node2:
              agents:
                - agent: worker
              dependencies: [node1]
          start_node: node1
      YAML

      orchestrator = SwarmSDK.load(yaml, base_dir: ".")

      # Mock LLM responses for both nodes
      stub_llm_request(mock_llm_response(content: "Node 1 done"))
      stub_llm_request(mock_llm_response(content: "Node 2 done"))

      execution_id = nil
      node_stop_events = []

      orchestrator.execute("Build system") do |event|
        # Capture execution_id
        execution_id ||= event[:execution_id]

        # Collect node_stop events (happen AFTER mini-swarm.execute)
        node_stop_events << event if event[:type] == "node_stop"
      end

      # All events share same execution_id
      refute_nil(execution_id, "Should have captured execution_id")

      # node_stop events must have IDs (proves mini-swarm didn't clear)
      node_stop_events.each do |event|
        assert_equal(
          execution_id,
          event[:execution_id],
          "node_stop missing execution_id - mini-swarm cleared it!",
        )
        refute_nil(event[:swarm_id], "node_stop missing swarm_id!")
      end

      assert_equal(2, node_stop_events.size, "Should have 2 node_stop events")
    end

    # Test execution_id format for standard swarm
    def test_execution_id_format_swarm
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      execution_id = nil

      swarm.execute("Test") do |event|
        execution_id ||= event[:execution_id]
      end

      assert_match(
        /^exec_[a-z0-9_]+_[a-f0-9]{16}$/,
        execution_id,
        "Swarm execution_id should match format: exec_{swarm_id}_{hex}",
      )
    end

    # Test execution_id format for workflow
    def test_execution_id_format_workflow
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Workflow"
          agents:
            worker:
              model: gpt-4o-mini
              description: "You are a worker"
              directory: "."
          nodes:
            node1:
              agents:
                - agent: worker
          start_node: node1
      YAML

      orchestrator = SwarmSDK.load(yaml, base_dir: ".")

      stub_llm_request(mock_llm_response(content: "Done"))

      execution_id = nil

      orchestrator.execute("Task") do |event|
        execution_id ||= event[:execution_id]
      end

      assert_match(
        /^exec_workflow_[a-f0-9]{16}$/,
        execution_id,
        "Workflow execution_id should match format: exec_workflow_{hex}",
      )
    end

    # Test that execution context is cleaned up after execution
    def test_fiber_storage_cleanup
      swarm = build_test_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Execute swarm
      swarm.execute("Test") { |_event| }

      # Fiber storage should be cleaned up after execution
      assert_nil(Fiber[:execution_id], "Fiber[:execution_id] should be nil after execution")
      assert_nil(Fiber[:swarm_id], "Fiber[:swarm_id] should be nil after execution")
      assert_nil(Fiber[:parent_swarm_id], "Fiber[:parent_swarm_id] should be nil after execution")
    end

    private

    def build_test_swarm
      build_test_swarm_with_name("Test Swarm")
    end

    def build_test_swarm_with_name(name)
      swarm = Swarm.new(name: name, scratchpad: Tools::Stores::ScratchpadStorage.new)

      swarm.add_agent(create_agent(
        name: :main,
        description: "Main agent",
        model: "gpt-4o-mini",
        system_prompt: "You are a test agent",
        directory: ".",
      ))

      swarm.lead = :main
      swarm
    end

    def create_agent(name:, description:, model:, system_prompt:, directory:)
      Agent::Definition.new(name, {
        description: description,
        model: model,
        system_prompt: system_prompt,
        directory: directory,
        tools: [],
      })
    end
  end
end
