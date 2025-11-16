# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class SnapshotFromEventsReconstructionTest < Minitest::Test
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

    def test_reconstruct_basic_snapshot_structure
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      # Reconstruct snapshot from events
      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify basic structure
      assert_equal("2.1.0", snapshot[:version])
      assert_equal("swarm", snapshot[:type])
      assert(snapshot[:snapshot_at])
      assert_equal(SwarmSDK::VERSION, snapshot[:swarm_sdk_version])

      # Verify main sections exist
      assert(snapshot[:metadata])
      assert(snapshot[:agents])
      assert(snapshot[:delegation_instances])
      assert(snapshot[:scratchpad])
      assert(snapshot[:read_tracking])
      assert(snapshot[:memory_read_tracking])
    end

    def test_reconstruct_swarm_metadata
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify swarm metadata
      assert(snapshot[:metadata][:id], "Missing swarm ID")
      assert(snapshot[:metadata][:first_message_sent])
    end

    def test_reconstruct_agent_conversations
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Agent response"))

      capture_io do
        swarm.execute("Test prompt") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify backend agent exists
      assert(snapshot[:agents]["backend"], "Missing backend agent in snapshot")

      # Verify conversation exists
      conversation = snapshot[:agents]["backend"][:conversation]

      assert(conversation, "Missing conversation")
      refute_empty(conversation, "Conversation should not be empty")

      # Verify we have messages
      assert_kind_of(Array, conversation, "Conversation should be an array")

      # Check message structure
      conversation.each do |msg|
        assert(msg[:role], "Message missing role")
        assert(msg.key?(:content), "Message missing content")
      end
    end

    def test_reconstruct_delegation_instances
      swarm = build_swarm_with_delegations
      events = []

      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          { name: "WorkWithWorker", arguments: { message: "Work" } },
        ]),
        mock_llm_response(content: "Work done"),
        mock_llm_response(content: "Complete"),
      )

      capture_io do
        swarm.execute("Delegate task") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify delegation instances section
      delegation_instances = snapshot[:delegation_instances]

      assert(delegation_instances, "Missing delegation_instances")

      # Should have worker@lead delegation instance
      delegation_name = delegation_instances.keys.find { |k| k.to_s.include?("worker") && k.to_s.include?("@") }

      assert(delegation_name, "Expected delegation instance like 'worker@lead'")

      # Verify delegation has conversation
      delegation_data = delegation_instances[delegation_name]

      assert(delegation_data[:conversation], "Delegation missing conversation")
      assert(delegation_data[:context_state], "Delegation missing context_state")
    end

    def test_reconstruct_scratchpad
      swarm = build_test_swarm
      events = []

      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "notes/summary",
              content: "This is a summary of the work",
              title: "Summary",
            },
          },
        ]),
        mock_llm_response(content: "Scratchpad updated"),
      )

      capture_io do
        swarm.execute("Write summary") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify scratchpad
      scratchpad = snapshot[:scratchpad]

      assert(scratchpad, "Missing scratchpad")

      # Verify entry exists
      entry = scratchpad["notes/summary"]

      assert(entry, "Missing scratchpad entry")
      assert_equal("This is a summary of the work", entry[:content])
      assert_equal("Summary", entry[:title])
      assert(entry[:updated_at], "Missing updated_at")
      # Size should match content bytesize
      assert_equal("This is a summary of the work".bytesize, entry[:size])
    end

    def test_reconstruct_read_tracking
      swarm = build_test_swarm
      events = []

      test_file = File.join(@test_dir, "test.rb")
      File.write(test_file, "# test code")

      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        mock_llm_response(content: "File read"),
      )

      capture_io do
        swarm.execute("Read file") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify read tracking
      read_tracking = snapshot[:read_tracking]

      assert(read_tracking, "Missing read_tracking")

      # Verify backend agent tracking (use string key)
      backend_tracking = read_tracking["backend"]

      assert(backend_tracking, "Missing backend read tracking")

      # Verify file is tracked with digest
      digest = backend_tracking[test_file]

      assert(digest, "File not tracked")
      assert_match(/\A[a-f0-9]{64}\z/, digest, "Invalid digest format")
    end

    def test_reconstruct_todowrite_index
      swarm = build_test_swarm
      events = []

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
        mock_llm_response(content: "Todos created"),
      )

      capture_io do
        swarm.execute("Create todos") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify context state
      context_state = snapshot[:agents]["backend"][:context_state]

      assert(context_state, "Missing context_state")

      # Verify todowrite index is set
      todowrite_index = context_state[:last_todowrite_message_index]

      assert_kind_of(Integer, todowrite_index, "TodoWrite index should be an integer")
      assert_operator(todowrite_index, :>=, 0, "TodoWrite index should be non-negative")
    end

    def test_round_trip_snapshot_reconstruction
      # Create swarm and execute
      swarm1 = build_test_swarm
      events = []

      test_file = File.join(@test_dir, "data.txt")
      File.write(test_file, "original data")

      stub_llm_sequence(
        # First execution
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "status",
              content: "Work in progress",
              title: "Status",
            },
          },
        ]),
        mock_llm_response(content: "First task done"),
        # Second execution (after restore)
        mock_llm_response(content: "Second task done"),
      )

      # First execution
      capture_io do
        swarm1.execute("First task") { |event| events << event }
      end

      # Reconstruct snapshot from events
      reconstructed_snapshot = SnapshotFromEvents.reconstruct(events)

      # Create new swarm and restore from reconstructed snapshot
      swarm2 = build_test_swarm
      restore_result = swarm2.restore(reconstructed_snapshot)

      assert_predicate(restore_result, :success?, "Restore should succeed")

      # Verify state was restored
      # 1. Conversation should have history
      backend_agent = swarm2.agent(:backend)

      refute_empty(backend_agent.messages, "Messages should be restored")

      # 2. Scratchpad should be restored
      scratchpad_entries = swarm2.scratchpad_storage.all_entries
      scratchpad_entry = scratchpad_entries["status"]

      assert(scratchpad_entry, "Scratchpad entry 'status' should be restored")
      assert_equal("Work in progress", scratchpad_entry.content)
      assert_equal("Status", scratchpad_entry.title)

      # 3. Read tracking should be restored
      assert(Tools::Stores::ReadTracker.file_read?(:backend, test_file), "Read tracking should be restored")

      # Execute second task on restored swarm
      result2 = capture_io do
        swarm2.execute("Second task") { |_event| }
      end

      assert(result2, "Second execution should work")
    end

    def test_reconstruct_context_state
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify context state structure
      context_state = snapshot[:agents]["backend"][:context_state]

      assert(context_state, "Missing context_state")
      assert(context_state.key?(:warning_thresholds_hit), "Missing warning_thresholds_hit")
      assert(context_state.key?(:compression_applied), "Missing compression_applied")
      assert(context_state.key?(:last_todowrite_message_index), "Missing last_todowrite_message_index")
      assert(context_state.key?(:active_skill_path), "Missing active_skill_path")
    end

    def test_multiple_scratchpad_writes_last_wins
      swarm = build_test_swarm
      events = []

      stub_llm_sequence(
        # First write
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "status",
              content: "Initial status",
              title: "Status",
            },
          },
        ]),
        # Second write (overwrites)
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "status",
              content: "Updated status",
              title: "Status Updated",
            },
          },
        ]),
        mock_llm_response(content: "Done"),
      )

      capture_io do
        swarm.execute("Update status") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Last write should win
      entry = snapshot[:scratchpad]["status"]

      assert_equal("Updated status", entry[:content])
      assert_equal("Status Updated", entry[:title])
    end

    def test_multiple_reads_last_digest_wins
      swarm = build_test_swarm
      events = []

      test_file = File.join(@test_dir, "file.txt")
      File.write(test_file, "version 1")

      stub_llm_sequence(
        # First read
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        mock_llm_response(content: "Read done"),
      )

      capture_io do
        swarm.execute("Read first") { |event| events << event }
      end

      # Modify file
      File.write(test_file, "version 2")

      stub_llm_sequence(
        # Second read (new digest)
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        mock_llm_response(content: "Read again"),
      )

      capture_io do
        swarm.execute("Read second") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Last read digest should be stored (use string key for agent)
      backend_tracking = snapshot[:read_tracking]["backend"]

      assert(backend_tracking, "Backend tracking should exist")

      digest = backend_tracking[test_file]

      assert(digest, "Digest should be tracked")

      # Verify it's the digest of "version 2"
      expected_digest = Digest::SHA256.hexdigest("version 2")

      assert_equal(expected_digest, digest)
    end

    def test_empty_events_produces_minimal_snapshot
      events = []

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Should have structure but empty content
      assert_equal("2.1.0", snapshot[:version])
      assert_empty(snapshot[:agents])
      assert_empty(snapshot[:delegation_instances])
      assert_empty(snapshot[:scratchpad])
      assert_empty(snapshot[:read_tracking])
      assert_empty(snapshot[:memory_read_tracking])
    end

    def test_reconstruct_matches_direct_snapshot
      swarm = build_test_swarm
      events = []

      test_file = File.join(@test_dir, "code.rb")
      File.write(test_file, "def hello\n  puts 'hi'\nend")

      stub_llm_sequence(
        mock_llm_response(tool_calls: [
          { name: "Read", arguments: { file_path: test_file } },
        ]),
        mock_llm_response(tool_calls: [
          {
            name: "ScratchpadWrite",
            arguments: {
              file_path: "analysis",
              content: "Code analysis here",
              title: "Analysis",
            },
          },
        ]),
        mock_llm_response(content: "Analysis complete"),
      )

      capture_io do
        swarm.execute("Analyze code") { |event| events << event }
      end

      # Get direct snapshot
      direct_snapshot = swarm.snapshot.to_hash

      # Get reconstructed snapshot
      reconstructed_snapshot = SnapshotFromEvents.reconstruct(events)

      # Compare key components
      assert_equal(direct_snapshot[:metadata][:id], reconstructed_snapshot[:metadata][:id])
      assert_equal(direct_snapshot[:metadata][:parent_id], reconstructed_snapshot[:metadata][:parent_id])
      assert_equal(direct_snapshot[:metadata][:first_message_sent], reconstructed_snapshot[:metadata][:first_message_sent])

      # Compare agents
      assert_equal(direct_snapshot[:agents].keys.sort, reconstructed_snapshot[:agents].keys.sort)

      # Compare conversations (message count may differ slightly due to system messages)
      direct_messages = direct_snapshot[:agents]["backend"][:conversation]
      reconstructed_messages = reconstructed_snapshot[:agents]["backend"][:conversation]

      # Both should have messages
      refute_empty(direct_messages, "Direct snapshot should have messages")
      refute_empty(reconstructed_messages, "Reconstructed snapshot should have messages")

      # Reconstructed should have most messages (might miss some system messages)
      assert_operator(
        reconstructed_messages.size,
        :>=,
        direct_messages.size - 2,
        "Reconstructed should have most messages",
      )

      # Compare scratchpad
      assert_equal(direct_snapshot[:scratchpad].keys.sort, reconstructed_snapshot[:scratchpad].keys.sort)
      if direct_snapshot[:scratchpad]["analysis"]
        assert_equal(
          direct_snapshot[:scratchpad]["analysis"][:content],
          reconstructed_snapshot[:scratchpad]["analysis"][:content],
        )
      end

      # Compare read tracking
      assert_equal(
        direct_snapshot[:read_tracking].keys.sort,
        reconstructed_snapshot[:read_tracking].keys.sort,
      )
    end

    def test_full_round_trip_restore_and_continue
      # Build and execute
      swarm1 = build_test_swarm
      events = []

      stub_llm_sequence(
        mock_llm_response(content: "First response"),
        mock_llm_response(content: "Second response"),
      )

      capture_io do
        swarm1.execute("First task") { |event| events << event }
      end

      # Reconstruct snapshot
      snapshot = SnapshotFromEvents.reconstruct(events)

      # Restore to new swarm
      swarm2 = build_test_swarm
      restore_result = swarm2.restore(snapshot)

      assert_predicate(restore_result, :success?, "Restore should succeed: #{restore_result.warnings.inspect}")

      # Continue conversation
      capture_io do
        result = swarm2.execute("Second task") { |_event| }

        assert_predicate(result, :success?, "Continued execution should work")
      end

      # Verify history is maintained
      backend = swarm2.agent(:backend)

      assert_operator(backend.messages.size, :>, 2, "Should have history from both executions")
    end

    def test_reconstruct_with_multiple_agents
      swarm = build_multi_agent_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Lead response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Should have lead agent at minimum
      assert(snapshot[:agents]["lead"], "Missing lead agent")

      # Verify all agents from events are in snapshot
      agent_names_in_events = events
        .map { |e| e[:agent]&.to_s }
        .compact
        .uniq
        .reject { |n| n.include?("@") } # Exclude delegations

      agent_names_in_snapshot = snapshot[:agents].keys

      agent_names_in_events.each do |agent_name|
        assert_includes(agent_names_in_snapshot, agent_name, "Agent #{agent_name} missing from snapshot")
      end
    end

    def test_reconstruct_context_state_compression
      build_test_swarm
      events = []

      # Add a compression_completed event manually to test reconstruction
      events << {
        type: "compression_completed",
        agent: :backend,
        timestamp: "2025-11-04T15:00:00Z",
      }

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify compression_applied is true
      context_state = snapshot[:agents]["backend"][:context_state]

      assert(context_state[:compression_applied])
    end

    def test_reconstruct_context_state_without_compression
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify compression_applied is nil (not false!)
      context_state = snapshot[:agents]["backend"][:context_state]

      assert_nil(context_state[:compression_applied], "Should be nil when no compression")
    end

    def test_reconstruct_warning_thresholds
      build_test_swarm
      events = []

      # Add threshold hit events
      events << {
        type: "context_threshold_hit",
        agent: :backend,
        threshold: 80,
        timestamp: "2025-11-04T15:00:00Z",
      }
      events << {
        type: "context_threshold_hit",
        agent: :backend,
        threshold: 90,
        timestamp: "2025-11-04T15:01:00Z",
      }

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify thresholds
      context_state = snapshot[:agents]["backend"][:context_state]
      thresholds = context_state[:warning_thresholds_hit]

      assert_equal([80, 90], thresholds)
    end

    def test_reconstruct_system_prompt_from_last_agent_start
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      # Reconstruct snapshot from events
      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify system prompt is extracted from agent_start event
      backend_data = snapshot[:agents]["backend"]

      assert(backend_data[:system_prompt], "System prompt should be present")
      assert_includes(backend_data[:system_prompt], "Backend agent", "Should include custom prompt")
    end

    def test_reconstruct_system_prompt_uses_last_event
      build_test_swarm
      events = []

      # Simulate multiple agent_start events (e.g., swarm restarted with updated config)
      events << {
        type: "agent_start",
        agent: :backend,
        system_prompt: "Old prompt",
        timestamp: "2025-11-04T15:00:00Z",
      }
      events << {
        type: "agent_start",
        agent: :backend,
        system_prompt: "Updated prompt",
        timestamp: "2025-11-04T15:01:00Z",
      }

      snapshot = SnapshotFromEvents.reconstruct(events)

      # Verify we use the LAST agent_start event's system prompt
      backend_data = snapshot[:agents]["backend"]

      assert_equal("Updated prompt", backend_data[:system_prompt])
    end

    def test_restore_applies_system_prompt_from_snapshot
      swarm = build_test_swarm
      events = []

      stub_llm_request(mock_llm_response(content: "Response 1"))

      capture_io do
        swarm.execute("Test") { |event| events << event }
      end

      # Reconstruct snapshot with system prompt
      snapshot_data = SnapshotFromEvents.reconstruct(events)

      # Verify system prompt is in snapshot
      backend_data = snapshot_data[:agents]["backend"]

      assert(backend_data[:system_prompt], "Snapshot should contain system prompt")
      assert_includes(backend_data[:system_prompt], "Backend agent")

      # Create new swarm and restore
      new_swarm = build_test_swarm
      result = new_swarm.restore(snapshot_data)

      assert_predicate(result, :success?, "Restore should succeed")

      # Verify agent is functional after restore with correct system prompt
      # The agent should have the restored system prompt applied via with_instructions()
      backend_agent = new_swarm.agent(:backend)

      assert(backend_agent, "Agent should be initialized")

      # Execute to verify agent works with restored system prompt
      stub_llm_request(mock_llm_response(content: "Response 2"))
      capture_io do
        response = new_swarm.execute("Another test")

        assert_predicate(response, :success?, "Restored agent should execute successfully")
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
        description: "Backend",
        model: "gpt-4",
        system_prompt: "Backend agent",
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

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-4",
        system_prompt: "Lead agent",
        directory: @test_dir,
        delegates_to: [:worker],
      ))

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
  end
end
