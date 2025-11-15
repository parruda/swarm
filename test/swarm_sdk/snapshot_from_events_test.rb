# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class SnapshotFromEventsTest < Minitest::Test
    include LLMMockHelper

    def setup
      @test_dir = Dir.mktmpdir
      ENV["OPENAI_API_KEY"] = "test-key"
      RubyLLM.configure { |config| config.openai_api_key = "test-key" }
    end

    def teardown
      FileUtils.rm_rf(@test_dir)
      LogStream.reset!
      LogCollector.reset!
      WebMock.reset!
      Tools::Stores::ReadTracker.clear_all
      ENV.delete("OPENAI_API_KEY")
    end

    def test_all_agents_emit_events_not_just_lead
      swarm = Swarm.new(name: "Test Swarm", scratchpad: Tools::Stores::ScratchpadStorage.new)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead developer",
        model: "gpt-5",
        system_prompt: "You are a lead developer",
        directory: @test_dir,
      ))

      swarm.lead = :lead

      events = []
      stub_llm_request(mock_llm_response(content: "Response from lead"))

      # Execute
      capture_io do
        swarm.execute("Test task") { |event| events << event }
      end

      # Verify we have events from the lead agent
      lead_events = events.select { |e| e[:agent] == :lead }

      refute_empty(lead_events, "Expected events from lead agent")

      # Verify we have different event types from the agent
      event_types = events.map { |e| e[:type] }.uniq

      assert_includes(event_types, "user_prompt", "Missing user_prompt event. Got: #{event_types.inspect}")
      assert_includes(event_types, "agent_stop", "Missing agent_stop event")
    end

    def test_delegation_instances_emit_events_with_instance_name
      swarm = build_swarm_with_delegations

      events = []

      # Mock responses for both lead and delegate
      stub_llm_sequence(
        # Lead makes delegation
        mock_llm_response(tool_calls: [
          { name: "WorkWithWorker", arguments: { message: "Do work" } },
        ]),
        # Worker responds
        mock_llm_response(content: "Work done"),
        # Lead final response
        mock_llm_response(content: "Task completed"),
      )

      capture_io do
        swarm.execute("Delegate this task") { |event| events << event }
      end

      # Verify we have events from the delegation instance
      delegation_events = events.select { |e| e[:agent].to_s.include?("@") }

      refute_empty(delegation_events, "Expected events from delegation instance (worker@lead)")

      # The delegation instance name should be "worker@lead"
      delegation_instance_name = delegation_events.first[:agent]

      assert_match(/@/, delegation_instance_name.to_s, "Delegation instance should have @ in name")

      # Verify delegation has its own conversation events
      delegation_types = delegation_events.map { |e| e[:type] }.uniq

      assert_includes(delegation_types, "user_prompt", "Delegation missing user_prompt")
      assert_includes(delegation_types, "agent_stop", "Delegation missing agent_stop")
    end

    def test_context_threshold_hit_events_emitted
      skip("Context thresholds require many executions to trigger naturally - tested in integration")

      # This test would verify that context_threshold_hit events are emitted
      # when context usage crosses thresholds (60%, 80%, 90%, 95%)
      # However, it requires accumulating significant tokens which is slow to mock
    end

    def test_read_tracking_digest_in_tool_result_metadata
      swarm = build_test_swarm
      events = []

      # Create a test file
      test_file = File.join(@test_dir, "test.txt")
      File.write(test_file, "test content")

      # Mock response that reads the file
      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        mock_llm_response(content: "File read"),
      )

      capture_io do
        swarm.execute("Read the file") { |event| events << event }
      end

      # Find Read tool_result event
      read_result = events.find { |e| e[:type] == "tool_result" && e[:tool] == "Read" }

      refute_nil(read_result, "Expected Read tool_result event")

      # Verify digest in metadata
      assert(read_result[:metadata], "tool_result missing metadata")
      assert(read_result.dig(:metadata, :read_digest), "tool_result metadata missing read_digest")
      assert(read_result.dig(:metadata, :read_path), "tool_result metadata missing read_path")

      # Verify digest is a valid SHA256 hex string
      digest = read_result.dig(:metadata, :read_digest)

      assert_match(/\A[a-f0-9]{64}\z/, digest, "Digest should be 64-char hex SHA256")
    end

    def test_scratchpad_state_captured_in_tool_call_arguments
      swarm = build_test_swarm
      events = []

      # Mock response with scratchpad write
      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "notes/test",
              content: "Test content for scratchpad",
              title: "Test Note",
            },
          },
        ]),
        mock_llm_response(content: "Done"),
      )

      capture_io do
        swarm.execute("Write to scratchpad") { |event| events << event }
      end

      # Find ScratchpadWrite tool_call
      scratchpad_call = events.find { |e| e[:type] == "tool_call" && e[:tool] == "ScratchpadWrite" }

      refute_nil(scratchpad_call, "Expected ScratchpadWrite tool_call event")

      # Verify full content is in arguments
      args = scratchpad_call[:arguments]

      assert(args, "Scratchpad call missing arguments")
      # Arguments may have string or symbol keys depending on serialization
      assert_equal("notes/test", args[:file_path] || args["file_path"])
      assert_equal("Test content for scratchpad", args[:content] || args["content"])
      assert_equal("Test Note", args[:title] || args["title"])
    end

    def test_todowrite_index_from_tool_call_events
      swarm = build_test_swarm
      events = []

      # Mock TodoWrite tool call
      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          {
            name: "TodoWrite",
            arguments: {
              todos: [
                { content: "Task 1", status: "pending", activeForm: "Task 1" },
              ],
            },
          },
        ]),
        mock_llm_response(content: "Tasks created"),
      )

      capture_io do
        swarm.execute("Create task") { |event| events << event }
      end

      # Find TodoWrite tool_call
      todowrite_call = events.find { |e| e[:type] == "tool_call" && e[:tool] == "TodoWrite" }

      refute_nil(todowrite_call, "Expected TodoWrite tool_call event")

      # This event has the tool_call_id we can use to find the message index
      assert(todowrite_call[:tool_call_id])
      assert_equal("TodoWrite", todowrite_call[:tool])
    end

    def test_active_skill_from_load_skill_tool_call
      skip("LoadSkill is a SwarmMemory tool, requires SwarmMemory setup")

      # This test would verify that LoadSkill tool_call events contain
      # the skill path in arguments[:file_path]
    end

    def test_all_events_have_timestamps
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      # Every single event must have a timestamp with microsecond precision
      events.each do |event|
        assert(event.key?(:timestamp), "Event missing timestamp: #{event[:type]}")
        assert_match(
          /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/,
          event[:timestamp],
          "Invalid timestamp format: #{event[:timestamp]}",
        )
      end
    end

    def test_events_maintain_chronological_order
      swarm = build_test_swarm
      events = []

      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          { name: "Think", arguments: { question: "Test" } },
        ]),
        mock_llm_response(content: "Done"),
      )

      capture_io do
        swarm.execute("Think about this") { |event| events << event }
      end

      # Verify timestamps are in order
      timestamps = events.map { |e| Time.parse(e[:timestamp]) }

      assert_equal(timestamps, timestamps.sort, "Events should be in chronological order")
    end

    def test_reconstruction_captures_all_agent_names
      swarm = build_multi_agent_swarm_with_delegations

      events = []
      stub_llm_sequence(
        # Lead calls worker
        mock_llm_response(tool_calls: [
          { name: "WorkWithWorker", arguments: { message: "Work" } },
        ]),
        # Worker responds
        mock_llm_response(content: "Work done"),
        # Lead final
        mock_llm_response(content: "Complete"),
      )

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      # Get unique agent names from events
      agent_names = events.map { |e| e[:agent] }.compact.uniq

      # Should have at least lead agent
      assert_includes(agent_names, :lead, "Missing lead agent in events")

      # Should have delegation instance (worker@lead)
      delegation_agents = agent_names.select { |name| name.to_s.include?("@") }

      refute_empty(delegation_agents, "Expected delegation instance events")
    end

    def test_all_state_components_present_in_events
      swarm = build_comprehensive_test_swarm
      events = []

      # Create test file for read tracking
      test_file = File.join(@test_dir, "test.rb")
      File.write(test_file, "# test file")

      # Mock complex interaction
      stub_llm_sequence(
        # Read file
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        # Write to scratchpad
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "notes", content: "Notes", title: "Notes",
            },
          },
        ]),
        # TodoWrite
        mock_llm_response(tool_calls: [
          {
            name: "TodoWrite",
            arguments: {
              todos: [
                { content: "Task", status: "pending", activeForm: "Task" },
              ],
            },
          },
        ]),
        # Final
        mock_llm_response(content: "All done"),
      )

      capture_io do
        swarm.execute("Do complex task") { |event| events << event }
      end

      event_types = events.map { |e| e[:type] }.uniq

      # Core events
      assert_includes(event_types, "user_prompt", "Missing user_prompt")
      assert_includes(event_types, "agent_step", "Missing agent_step")
      assert_includes(event_types, "agent_stop", "Missing agent_stop")
      assert_includes(event_types, "tool_call", "Missing tool_call")
      assert_includes(event_types, "tool_result", "Missing tool_result")

      # Verify we have Read with digest
      read_result = events.find { |e| e[:type] == "tool_result" && e[:tool] == "Read" }
      if read_result
        assert(read_result.dig(:metadata, :read_digest), "Read result missing digest")
      end

      # Verify we have ScratchpadWrite with full content
      scratchpad_call = events.find { |e| e[:type] == "tool_call" && e[:tool] == "ScratchpadWrite" }
      if scratchpad_call
        args = scratchpad_call[:arguments]
        # Arguments may have string or symbol keys
        content = args && (args[:content] || args["content"])

        assert(content, "ScratchpadWrite missing content. Args: #{args.inspect}")
      end

      # Verify we have TodoWrite
      todowrite_call = events.find { |e| e[:type] == "tool_call" && e[:tool] == "TodoWrite" }
      if todowrite_call
        assert(todowrite_call[:tool_call_id], "TodoWrite missing tool_call_id")
      end
    end

    private

    def build_test_swarm
      swarm = Swarm.new(
        name: "Test Swarm",
        scratchpad: Tools::Stores::ScratchpadStorage.new,
      )

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend dev",
        model: "gpt-4",
        system_prompt: "You are a backend developer",
        directory: @test_dir,
      ))

      swarm.lead = :backend
      swarm
    end

    def build_multi_agent_swarm
      swarm = Swarm.new(
        name: "Multi Agent",
        scratchpad: Tools::Stores::ScratchpadStorage.new,
      )

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-4",
        system_prompt: "Lead agent",
        directory: @test_dir,
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend",
        model: "gpt-4",
        system_prompt: "Backend agent",
        directory: @test_dir,
      ))

      swarm.lead = :lead
      swarm
    end

    def build_swarm_with_delegations
      swarm = Swarm.new(
        name: "Delegation Test",
        scratchpad: Tools::Stores::ScratchpadStorage.new,
      )

      # Lead agent with delegation
      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-4",
        system_prompt: "Lead agent",
        directory: @test_dir,
        delegates_to: [:worker],
      ))

      # Worker agent
      swarm.add_agent(create_agent(
        name: :worker,
        description: "Worker",
        model: "gpt-4",
        system_prompt: "Worker agent",
        directory: @test_dir,
      ))

      swarm.lead = :lead
      swarm
    end

    def build_multi_agent_swarm_with_delegations
      swarm = Swarm.new(
        name: "Complex Swarm",
        scratchpad: Tools::Stores::ScratchpadStorage.new,
      )

      # Lead with delegations
      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-4",
        system_prompt: "Lead",
        directory: @test_dir,
        delegates_to: [:worker, :tester],
      ))

      swarm.add_agent(create_agent(
        name: :worker,
        description: "Worker",
        model: "gpt-4",
        system_prompt: "Worker",
        directory: @test_dir,
      ))

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Tester",
        model: "gpt-4",
        system_prompt: "Tester",
        directory: @test_dir,
      ))

      swarm.lead = :lead
      swarm
    end

    def build_comprehensive_test_swarm
      swarm = Swarm.new(
        name: "Comprehensive",
        scratchpad: Tools::Stores::ScratchpadStorage.new,
      )

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend",
        model: "gpt-4",
        system_prompt: "Backend developer",
        directory: @test_dir,
        tools: ["Read", "Write", "Edit", "ScratchpadWrite", "ScratchpadRead", "TodoWrite"],
      ))

      swarm.lead = :backend
      swarm
    end
  end
end
