# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class StateRestorerTest < Minitest::Test
    # ========== Snapshot Input Type Tests ==========

    def test_restore_with_snapshot_object_input
      snapshot_data = create_valid_snapshot_hash
      snapshot_obj = Snapshot.new(snapshot_data)
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_obj)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      assert_predicate(result, :success?)
    end

    def test_restore_with_hash_input
      snapshot_data = create_valid_snapshot_hash
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      assert_predicate(result, :success?)
    end

    def test_restore_with_json_string_input
      snapshot_data = create_valid_snapshot_hash
      json_string = JSON.generate(snapshot_data)
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, json_string)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      assert_predicate(result, :success?)
    end

    def test_initialize_with_invalid_snapshot_input
      mock_swarm = create_mock_swarm(agents: [:alice])

      error = assert_raises(ArgumentError) do
        StateRestorer.new(mock_swarm, 123)
      end

      assert_match(/snapshot must be a Snapshot object, Hash, or JSON string/, error.message)
    end

    # ========== Version Validation Tests ==========

    def test_version_validation_with_valid_version
      snapshot_data = create_valid_snapshot_hash
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      # Should not raise
      assert_kind_of(StateRestorer, restorer)
    end

    def test_version_validation_with_missing_version
      snapshot_data = create_valid_snapshot_hash
      snapshot_data.delete(:version)
      mock_swarm = create_mock_swarm(agents: [:alice])

      error = assert_raises(StateError) do
        StateRestorer.new(mock_swarm, snapshot_data)
      end

      assert_match(/Unsupported snapshot version/, error.message)
    end

    def test_version_validation_with_wrong_version
      snapshot_data = create_valid_snapshot_hash
      snapshot_data[:version] = "1.0.0" # Old version is now wrong
      mock_swarm = create_mock_swarm(agents: [:alice])

      error = assert_raises(StateError) do
        StateRestorer.new(mock_swarm, snapshot_data)
      end

      assert_match(/Unsupported snapshot version: 1.0.0/, error.message)
    end

    def test_version_validation_with_string_keys
      snapshot_data = create_valid_snapshot_hash
      snapshot_data_str_keys = convert_keys_to_strings(snapshot_data)
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data_str_keys)

      assert_kind_of(StateRestorer, restorer)
    end

    # ========== Type Mismatch Tests ==========

    def test_type_mismatch_snapshot_swarm_vs_workflow
      snapshot_data = create_valid_snapshot_hash
      snapshot_data[:type] = :swarm
      mock_workflow = create_mock_workflow(agents: [:alice])

      error = assert_raises(StateError) do
        StateRestorer.new(mock_workflow, snapshot_data)
      end

      assert_match(/Snapshot type 'swarm' doesn't match orchestration type 'workflow'/, error.message)
    end

    def test_type_mismatch_snapshot_workflow_vs_swarm
      snapshot_data = create_valid_snapshot_hash
      snapshot_data[:type] = :workflow
      mock_swarm = create_mock_swarm(agents: [:alice])

      error = assert_raises(StateError) do
        StateRestorer.new(mock_swarm, snapshot_data)
      end

      assert_match(/Snapshot type 'workflow' doesn't match orchestration type 'swarm'/, error.message)
    end

    def test_type_matching_swarm_with_swarm
      snapshot_data = create_valid_snapshot_hash
      snapshot_data[:type] = :swarm
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)

      assert_kind_of(StateRestorer, restorer)
    end

    def test_type_matching_workflow_with_workflow
      snapshot_data = create_valid_snapshot_hash
      snapshot_data[:type] = :workflow
      mock_node_orch = create_mock_workflow(agents: [:alice])

      restorer = StateRestorer.new(mock_node_orch, snapshot_data)

      assert_kind_of(StateRestorer, restorer)
    end

    # ========== Agent Compatibility Tests ==========

    def test_agent_validation_all_agents_exist
      snapshot_data = create_valid_snapshot_hash(agents: [:alice, :bob])
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
      assert_empty(result.warnings)
      assert_empty(result.skipped_agents)
    end

    def test_agent_validation_some_agents_missing
      snapshot_data = create_valid_snapshot_hash(agents: [:alice, :bob, :charlie])
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :partial_restore?)
      assert_equal(1, result.skipped_agents.size)
      assert_includes(result.skipped_agents, :charlie)
      assert_equal(1, result.warnings.size)
      assert_equal(:agent_not_found, result.warnings[0][:type])
    end

    def test_agent_validation_all_agents_missing
      snapshot_data = create_valid_snapshot_hash(agents: [:alice, :bob])
      mock_swarm = create_mock_swarm(agents: [:charlie, :dave])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :partial_restore?)
      assert_equal(2, result.skipped_agents.size)
      assert_equal(2, result.warnings.size)
    end

    def test_agent_validation_with_empty_agents
      snapshot_data = create_valid_snapshot_hash(agents: [])
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
    end

    def test_agent_validation_more_agents_in_config_than_snapshot
      snapshot_data = create_valid_snapshot_hash(agents: [:alice])
      mock_swarm = create_mock_swarm(agents: [:alice, :bob, :charlie])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
    end

    # ========== Delegation Compatibility Tests ==========

    def test_delegation_validation_both_exist
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        delegations: { "alice@bob" => {} },
      )
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
      assert_empty(result.skipped_delegations)
    end

    def test_delegation_validation_base_agent_missing
      snapshot_data = create_valid_snapshot_hash(
        agents: [:bob],
        delegations: { "alice@bob" => {} },
      )
      mock_swarm = create_mock_swarm(agents: [:bob])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :partial_restore?)
      assert_equal(1, result.skipped_delegations.size)
      assert_includes(result.skipped_delegations, "alice@bob")
    end

    def test_delegation_validation_with_empty_delegations
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        delegations: {},
      )
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
      assert_empty(result.skipped_delegations)
    end

    # ========== Metadata Restore Tests ==========

    def test_metadata_restore_swarm_first_message_sent_false
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        swarm_metadata: { first_message_sent: false },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      refute(mock_swarm.first_message_sent)
    end

    # ========== Conversation Restore Tests ==========

    def test_restore_conversation_preserves_messages
      conversation = [
        { role: :user, content: "Hello", tool_calls: {} },
        { role: :assistant, content: "Hi there", tool_calls: {} },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: conversation },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])
      mock_agent = mock_swarm.agents[:alice]

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      # Should have system message (from with_instructions) + 2 messages
      assert_equal(3, mock_agent.messages.size)
    end

    def test_restore_conversation_clears_existing_messages
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: [{ role: :user, content: "New msg", tool_calls: {} }] },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])
      mock_agent = mock_swarm.agents[:alice]

      # Add existing messages
      mock_agent.messages << RubyLLM::Message.new(role: :user, content: "Old msg")

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      # Should only have system message + new message, old ones cleared
      assert_equal(2, mock_agent.messages.size)
    end

    # ========== Message Deserialization Tests ==========

    def test_deserialize_message_with_plain_string_content
      conversation = [
        { role: :user, content: "Plain text message", tool_calls: {} },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: conversation },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      # System message + user message
      assert_equal(2, mock_swarm.agents[:alice].messages.size)
      user_msg = mock_swarm.agents[:alice].messages.last

      assert_equal("Plain text message", user_msg.content)
    end

    def test_deserialize_message_with_content_object
      conversation = [
        {
          role: :assistant,
          content: {
            text: "Response text",
            attachments: [{ type: "file", path: "/path/to/file" }],
          },
          tool_calls: {},
        },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: conversation },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      assistant_msg = mock_swarm.agents[:alice].messages.last

      assert_kind_of(RubyLLM::Content, assistant_msg.content)
      assert_equal("Response text", assistant_msg.content.text)
    end

    def test_deserialize_message_with_tool_calls
      conversation = [
        {
          role: :assistant,
          content: "Calling a tool",
          tool_calls: [
            { id: "call_1", name: "Read", arguments: { path: "/file.txt" } },
            { id: "call_2", name: "Write", arguments: { content: "text" } },
          ],
        },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: conversation },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      assistant_msg = mock_swarm.agents[:alice].messages.last

      assert_equal(2, assistant_msg.tool_calls.size)
      assert(assistant_msg.tool_calls.key?("call_1"))
      assert_equal("Read", assistant_msg.tool_calls["call_1"].name)
    end

    def test_deserialize_message_with_all_fields
      conversation = [
        {
          role: :assistant,
          content: "Full message",
          tool_calls: [{ id: "call_1", name: "Bash", arguments: { cmd: "ls" } }],
          tool_call_id: "response_to_1",
          input_tokens: 100,
          output_tokens: 50,
          model_id: "claude-opus",
        },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: conversation },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      msg = mock_swarm.agents[:alice].messages.last

      assert_equal(:assistant, msg.role)
      assert_equal("Full message", msg.content)
      assert_equal("response_to_1", msg.tool_call_id)
      assert_equal(100, msg.input_tokens)
      assert_equal(50, msg.output_tokens)
      assert_equal("claude-opus", msg.model_id)
    end

    def test_deserialize_message_with_empty_tool_calls
      conversation = [
        { role: :user, content: "User message", tool_calls: [] },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        agent_conversations: { alice: conversation },
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      msg = mock_swarm.agents[:alice].messages.last

      assert(msg.tool_calls.nil? || msg.tool_calls.empty?)
    end

    # ========== Context State Restore Tests ==========

    def test_restore_context_state_warning_thresholds
      context_state = {
        warning_thresholds_hit: [100_000, 50_000],
        compression_applied: false,
        last_todowrite_message_index: nil,
        active_skill_path: nil,
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        context_state: context_state,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      agent = mock_swarm.agents[:alice]
      thresholds = agent.agent_context.warning_thresholds_hit

      assert_equal(2, thresholds.size)
      assert_includes(thresholds, 100_000)
      assert_includes(thresholds, 50_000)
    end

    def test_restore_context_state_compression_applied
      context_state = {
        warning_thresholds_hit: [],
        compression_applied: true,
        last_todowrite_message_index: 5,
        active_skill_path: nil,
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        context_state: context_state,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      agent = mock_swarm.agents[:alice]

      assert(agent.context_manager.compression_applied)
    end

    def test_restore_context_state_todowrite_index
      context_state = {
        warning_thresholds_hit: [],
        compression_applied: false,
        last_todowrite_message_index: 10,
        active_skill_path: nil,
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        context_state: context_state,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      agent = mock_swarm.agents[:alice]

      assert_equal(10, agent.last_todowrite_message_index)
    end

    def test_restore_context_state_active_skill_path
      context_state = {
        warning_thresholds_hit: [],
        compression_applied: false,
        last_todowrite_message_index: nil,
        active_skill_path: "/path/to/skill",
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        context_state: context_state,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      agent = mock_swarm.agents[:alice]

      assert_equal("/path/to/skill", agent.active_skill_path)
    end

    # ========== System Prompt Handling Tests ==========

    def test_restore_with_preserve_system_prompts_true
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        system_prompt_override: "Historical prompt",
      )
      mock_swarm = create_mock_swarm(
        agents: [:alice],
        system_prompt: "Current prompt",
      )

      restorer = StateRestorer.new(mock_swarm, snapshot_data, preserve_system_prompts: true)
      restorer.restore

      messages = mock_swarm.agents[:alice].messages
      system_message = messages.find { |m| m.role == :system }

      assert_equal("Historical prompt", system_message.content)
    end

    def test_restore_with_preserve_system_prompts_false
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        system_prompt_override: "Historical prompt",
      )
      mock_swarm = create_mock_swarm(
        agents: [:alice],
        system_prompt: "Current prompt",
      )

      restorer = StateRestorer.new(mock_swarm, snapshot_data, preserve_system_prompts: false)
      restorer.restore

      messages = mock_swarm.agents[:alice].messages
      system_message = messages.find { |m| m.role == :system }

      assert_equal("Current prompt", system_message.content)
    end

    # ========== Scratchpad Restore Tests (Swarm Only) ==========

    def test_restore_scratchpad_swarm_only
      scratchpad_data = [
        { id: "1", title: "Item 1", content: "Content 1" },
        { id: "2", title: "Item 2", content: "Content 2" },
      ]
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        scratchpad: scratchpad_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])
      mock_scratchpad = MockScratchpadStorage.new
      mock_swarm.scratchpad_storage = mock_scratchpad

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      assert_equal(scratchpad_data, mock_scratchpad.restored_entries)
    end

    def test_restore_scratchpad_workflow_enabled_mode
      scratchpad_data = {
        shared: true,
        data: { "path1" => { "content" => "data", "title" => "Item" } },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        scratchpad: scratchpad_data,
      )
      snapshot_data[:type] = "workflow"
      mock_node_orch = create_mock_workflow(agents: [:alice], scratchpad: :enabled)
      mock_scratchpad = MockScratchpadStorage.new
      mock_node_orch.setup_scratchpad_for(:planning, mock_scratchpad)

      restorer = StateRestorer.new(mock_node_orch, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      # Should restore scratchpad for Workflow (enabled/shared across nodes)
      assert_equal(scratchpad_data[:data], mock_scratchpad.restored_entries)
    end

    def test_restore_scratchpad_workflow_per_node_mode
      scratchpad_data = {
        shared: false,
        data: {
          "planning" => { "path1" => { "content" => "plan data", "title" => "Plan" } },
          "implementation" => { "path2" => { "content" => "impl data", "title" => "Impl" } },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        scratchpad: scratchpad_data,
      )
      snapshot_data[:type] = "workflow"
      mock_node_orch = create_mock_workflow(agents: [:alice], scratchpad: :per_node)

      planning_scratchpad = MockScratchpadStorage.new
      impl_scratchpad = MockScratchpadStorage.new
      mock_node_orch.setup_scratchpad_for(:planning, planning_scratchpad)
      mock_node_orch.setup_scratchpad_for(:implementation, impl_scratchpad)

      restorer = StateRestorer.new(mock_node_orch, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      # Should restore separate scratchpads for each node
      assert_equal(scratchpad_data[:data]["planning"], planning_scratchpad.restored_entries)
      assert_equal(scratchpad_data[:data]["implementation"], impl_scratchpad.restored_entries)
    end

    def test_restore_scratchpad_empty
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        scratchpad: [],
      )
      mock_swarm = create_mock_swarm(agents: [:alice])
      mock_scratchpad = MockScratchpadStorage.new
      mock_swarm.scratchpad_storage = mock_scratchpad

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      assert_empty(mock_scratchpad.restored_entries)
    end

    def test_restore_scratchpad_no_storage
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        scratchpad: [{ id: "1" }],
      )
      mock_swarm = create_mock_swarm(agents: [:alice])
      mock_swarm.scratchpad_storage = nil

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
    end

    # ========== Read Tracking Restore Tests ==========

    def test_restore_read_tracking_single_agent
      read_tracking_data = {
        alice: {
          "/file1.txt" => "digest1",
          "/file2.txt" => "digest2",
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        read_tracking: read_tracking_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      # Verify the test can create the restorer and restore
      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
    end

    def test_restore_read_tracking_multiple_agents
      read_tracking_data = {
        alice: { "/alice_file.txt" => "digest_a" },
        bob: { "/bob_file.txt" => "digest_b" },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        read_tracking: read_tracking_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      # Should succeed with multiple agents
      assert_kind_of(RestoreResult, result)
    end

    def test_restore_read_tracking_missing
      snapshot_data = create_valid_snapshot_hash(agents: [:alice])
      snapshot_data.delete(:read_tracking)
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
    end

    # ========== Version 2.1.0 Plugin State Tests ==========

    def test_version_210_accepted
      snapshot_data = create_valid_snapshot_hash(agents: [:alice], version: "2.1.0")
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)

      assert_kind_of(StateRestorer, restorer)
    end

    def test_version_200_rejected
      snapshot_data = create_valid_snapshot_hash(agents: [:alice], version: "2.0.0")
      mock_swarm = create_mock_swarm(agents: [:alice])

      error = assert_raises(StateError) do
        StateRestorer.new(mock_swarm, snapshot_data)
      end

      assert_match(/Unsupported snapshot version: 2.0.0/, error.message)
    end

    def test_restore_plugin_states_single_plugin_single_agent
      plugin_states_data = {
        "memory" => {
          "alice" => {
            read_entries: { "/entry1" => "digest1" },
          },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        plugin_states: plugin_states_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      # Register a test plugin
      test_plugin = TestStatePlugin.new(:memory)
      PluginRegistry.clear
      PluginRegistry.register(test_plugin)

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      # Verify plugin received the state
      assert_includes(test_plugin.restored_agents, :alice)
      restored_state = test_plugin.restored_states[:alice]

      assert_equal({ read_entries: { "/entry1" => "digest1" } }, restored_state)

      PluginRegistry.clear
    end

    def test_restore_plugin_states_multiple_plugins_multiple_agents
      plugin_states_data = {
        "memory" => {
          "alice" => { read_entries: { "/a_entry" => "a_digest" } },
          "bob" => { read_entries: { "/b_entry" => "b_digest" } },
        },
        "custom" => {
          "alice" => { custom_data: "alice_custom" },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        plugin_states: plugin_states_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])

      # Register test plugins
      memory_plugin = TestStatePlugin.new(:memory)
      custom_plugin = TestStatePlugin.new(:custom)
      PluginRegistry.clear
      PluginRegistry.register(memory_plugin)
      PluginRegistry.register(custom_plugin)

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      # Verify memory plugin received both agents
      assert_includes(memory_plugin.restored_agents, :alice)
      assert_includes(memory_plugin.restored_agents, :bob)
      # Verify custom plugin received only alice
      assert_includes(custom_plugin.restored_agents, :alice)
      refute_includes(custom_plugin.restored_agents, :bob)

      PluginRegistry.clear
    end

    def test_restore_plugin_states_missing_plugin_gracefully_skipped
      plugin_states_data = {
        "nonexistent_plugin" => {
          "alice" => { some_data: "value" },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        plugin_states: plugin_states_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      PluginRegistry.clear

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      # Should succeed even with missing plugin
      assert_predicate(result, :success?)
    end

    def test_restore_empty_plugin_states
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        plugin_states: {},
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
    end

    def test_restore_with_string_keys_in_plugin_states
      plugin_states_data = {
        "memory" => {
          "alice" => {
            "read_entries" => { "/entry1" => "digest1" },
          },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        plugin_states: plugin_states_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice])

      test_plugin = TestStatePlugin.new(:memory)
      PluginRegistry.clear
      PluginRegistry.register(test_plugin)

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
      # Should symbolize keys
      restored_state = test_plugin.restored_states[:alice]

      assert_equal({ read_entries: { "/entry1" => "digest1" } }, restored_state)

      PluginRegistry.clear
    end

    # ========== Delegation Conversation Restore Tests ==========

    def test_restore_delegation_conversation_swarm
      delegation_data = {
        "alice@bob" => {
          conversation: [
            { role: :user, content: "Delegate task", tool_calls: {} },
          ],
          system_prompt: "Delegation prompt",
          context_state: {
            warning_thresholds_hit: [],
            compression_applied: false,
            last_todowrite_message_index: nil,
            active_skill_path: nil,
          },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        delegations: delegation_data,
      )
      mock_swarm = create_mock_swarm(agents: [:alice, :bob])
      mock_delegation = MockDelegationChat.new
      mock_swarm.delegation_instances["alice@bob"] = mock_delegation

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      restorer.restore

      assert_equal(2, mock_delegation.messages.size) # system + 1 user
    end

    def test_restore_delegation_conversation_workflow_not_cached
      delegation_data = {
        "alice@bob" => {
          conversation: [
            { role: :user, content: "Task", tool_calls: {} },
          ],
          system_prompt: "Prompt",
          context_state: {
            warning_thresholds_hit: [],
            compression_applied: false,
            last_todowrite_message_index: nil,
            active_skill_path: nil,
          },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        delegations: delegation_data,
      )
      snapshot_data[:type] = :workflow
      mock_node_orch = create_mock_workflow(agents: [:alice, :bob])
      # Empty cache (not yet initialized)
      mock_node_orch.delegation_instances.clear

      restorer = StateRestorer.new(mock_node_orch, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
    end

    # ========== Preserve System Prompts with Delegations ==========

    def test_delegation_restore_preserve_system_prompts_true
      delegation_data = {
        "alice@bob" => {
          conversation: [
            { role: :user, content: "Task", tool_calls: {} },
          ],
          system_prompt: "Historical delegation prompt",
          context_state: {
            warning_thresholds_hit: [],
            compression_applied: false,
            last_todowrite_message_index: nil,
            active_skill_path: nil,
          },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        delegations: delegation_data,
        system_prompt_override: "Historical alice prompt",
      )
      mock_swarm = create_mock_swarm(
        agents: [:alice, :bob],
        system_prompt: "Current alice prompt",
      )
      mock_delegation = MockDelegationChat.new
      mock_swarm.delegation_instances["alice@bob"] = mock_delegation

      restorer = StateRestorer.new(mock_swarm, snapshot_data, preserve_system_prompts: true)
      restorer.restore

      # Should use historical delegation prompt
      system_msg = mock_delegation.messages.find { |m| m.role == :system }

      assert_equal("Historical delegation prompt", system_msg.content)
    end

    def test_delegation_restore_preserve_system_prompts_false
      delegation_data = {
        "alice@bob" => {
          conversation: [
            { role: :user, content: "Task", tool_calls: {} },
          ],
          system_prompt: "Historical delegation prompt",
          context_state: {
            warning_thresholds_hit: [],
            compression_applied: false,
            last_todowrite_message_index: nil,
            active_skill_path: nil,
          },
        },
      }
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice, :bob],
        delegations: delegation_data,
        system_prompt_override: "Historical alice prompt",
      )
      mock_swarm = create_mock_swarm(
        agents: [:alice, :bob],
        system_prompt: "Current alice prompt",
      )
      mock_delegation = MockDelegationChat.new
      mock_swarm.delegation_instances["alice@bob"] = mock_delegation

      restorer = StateRestorer.new(mock_swarm, snapshot_data, preserve_system_prompts: false)
      restorer.restore

      # Should use current alice prompt
      system_msg = mock_delegation.messages.find { |m| m.role == :system }

      assert_equal("Current alice prompt", system_msg.content)
    end

    # ========== Edge Cases and Error Handling ==========

    def test_restore_result_success_method
      snapshot_data = create_valid_snapshot_hash(agents: [:alice])
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
      assert_includes(result.summary, "All agents restored")
    end

    def test_restore_result_partial_restore_method
      snapshot_data = create_valid_snapshot_hash(agents: [:alice, :bob])
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :partial_restore?)
      assert_match(/Snapshot restored with warnings/, result.summary)
    end

    def test_restore_with_string_keys_in_snapshot
      snapshot_data = convert_keys_to_strings(create_valid_snapshot_hash(agents: [:alice]))
      mock_swarm = create_mock_swarm(agents: [:alice])

      restorer = StateRestorer.new(mock_swarm, snapshot_data)
      result = restorer.restore

      assert_predicate(result, :success?)
    end

    def test_restore_agent_not_in_cache_for_workflow
      snapshot_data = create_valid_snapshot_hash(agents: [:alice])
      snapshot_data[:type] = :workflow
      mock_node_orch = create_mock_workflow(agents: [:alice])
      # Agent not yet in cache
      mock_node_orch.agents.clear

      restorer = StateRestorer.new(mock_node_orch, snapshot_data)
      result = restorer.restore

      assert_kind_of(RestoreResult, result)
    end

    def test_restore_with_nil_system_prompt_in_snapshot
      snapshot_data = create_valid_snapshot_hash(
        agents: [:alice],
        system_prompt_override: nil,
      )
      mock_swarm = create_mock_swarm(agents: [:alice], system_prompt: nil)

      restorer = StateRestorer.new(mock_swarm, snapshot_data, preserve_system_prompts: true)
      result = restorer.restore

      assert_predicate(result, :success?)
    end

    private

    def create_valid_snapshot_hash(
      agents: [:alice],
      delegations: {},
      agent_conversations: nil,
      context_state: nil,
      system_prompt_override: nil,
      scratchpad: nil,
      read_tracking: nil,
      plugin_states: nil,
      version: "2.1.0",
      swarm_metadata: {}
    )
      agent_conversations ||= agents.each_with_object({}) do |agent, hash|
        hash[agent] = [
          { role: :user, content: "Test message", tool_calls: {} },
        ]
      end

      context_state ||= {
        warning_thresholds_hit: [],
        compression_applied: false,
        last_todowrite_message_index: nil,
        active_skill_path: nil,
      }

      agents_data = agents.each_with_object({}) do |agent_name, hash|
        hash[agent_name] = {
          conversation: agent_conversations[agent_name],
          system_prompt: system_prompt_override || "Test prompt for #{agent_name}",
          context_state: context_state,
        }
      end

      delegations_data = delegations.each_with_object({}) do |(name, data), hash|
        # Use string keys for delegations to match actual JSON parsing
        hash[name.to_s] = {
          conversation: data[:conversation] || [{ role: :user, content: "Task", tool_calls: {} }],
          system_prompt: data[:system_prompt] || "Delegation prompt",
          context_state: data[:context_state] || context_state,
        }
      end

      snapshot = {
        version: version,
        type: :swarm,
        snapshot_at: Time.now.iso8601,
        swarm_sdk_version: SwarmSDK::VERSION,
        metadata: swarm_metadata.merge(first_message_sent: false),
        agents: agents_data,
        delegation_instances: delegations_data,
      }

      snapshot[:scratchpad] = scratchpad if scratchpad
      snapshot[:read_tracking] = read_tracking if read_tracking
      snapshot[:plugin_states] = plugin_states if plugin_states

      snapshot
    end

    def convert_keys_to_strings(hash)
      case hash
      when Hash
        hash.each_with_object({}) do |(k, v), result|
          result[k.to_s] = convert_keys_to_strings(v)
        end
      when Array
        hash.map { |item| convert_keys_to_strings(item) }
      else
        hash
      end
    end

    def create_mock_swarm(agents: [], system_prompt: nil)
      MockSwarm.new(agents: agents, system_prompt: system_prompt)
    end

    def create_mock_workflow(agents: [], scratchpad: :enabled)
      MockWorkflow.new(agents: agents, scratchpad: scratchpad)
    end

    # Mock Classes for testing

    class MockAgentDef
      attr_reader :system_prompt

      def initialize(system_prompt)
        @system_prompt = system_prompt
      end
    end

    class MockWorkflow
      attr_reader :agents, :delegation_instances, :scratchpad, :start_node, :swarm_id, :parent_swarm_id

      # Identify as Workflow for type detection
      def is_a?(klass)
        return true if klass == SwarmSDK::Workflow

        super
      end

      def kind_of?(klass)
        return true if klass == SwarmSDK::Workflow

        super
      end

      # Override class name for type detection
      class << self
        def name
          "SwarmSDK::Workflow"
        end
      end

      def initialize(agents: [], scratchpad: :enabled)
        @agent_defs = {}
        @agents = {}                    # Updated to match Workflow
        @delegation_instances = {}      # Updated to match Workflow
        @scratchpad = scratchpad
        @start_node = :planning # Default for tests
        @scratchpads = {} # { node_name => scratchpad }
        @swarm_id = nil
        @parent_swarm_id = nil

        agents.each do |agent_name|
          @agent_defs[agent_name] = MockAgentDef.new("Test prompt")
        end
      end

      def agent_definitions
        @agent_defs
      end

      # Implement Snapshotable interface
      def primary_agents
        @agents
      end

      def delegation_instances_hash
        @delegation_instances
      end

      def first_message_sent?
        false
      end

      def name
        "MockWorkflow"
      end

      def shared_scratchpad?
        @scratchpad == :enabled
      end

      # Setup a scratchpad for a specific node (for testing)
      def setup_scratchpad_for(node_name, scratchpad)
        @scratchpads[node_name] = scratchpad
      end

      # Get scratchpad for a specific node
      def scratchpad_for(node_name)
        @scratchpads[node_name]
      end

      # Get all scratchpads (for snapshot)
      def all_scratchpads
        case @scratchpad
        when :enabled
          { shared: @scratchpads[@start_node] }
        when :per_node
          @scratchpads.dup
        when :disabled
          {}
        end
      end

      # Backward compatibility
      def shared_scratchpad_storage
        @scratchpads[@start_node]
      end

      def shared_scratchpad_storage=(scratchpad)
        @scratchpads[@start_node] = scratchpad
      end
    end

    class MockSwarm
      attr_reader :agents, :swarm_id, :parent_swarm_id
      attr_accessor :first_message_sent, :delegation_instances, :scratchpad_storage

      # Override class name for type detection
      class << self
        def name
          "SwarmSDK::Swarm"
        end
      end

      def initialize(agents: [], system_prompt: nil)
        @agent_defs = {}
        @agents = {}
        @swarm_id = nil
        @parent_swarm_id = nil

        agents.each do |agent_name|
          chat = MockAgentChat.new
          @agents[agent_name] = chat
          @agent_defs[agent_name] = MockAgentDef.new(system_prompt || "Test prompt")
        end

        @first_message_sent = nil
        @delegation_instances = {}
        @scratchpad_storage = nil
      end

      # Implement Snapshotable interface
      def primary_agents
        @agents
      end

      def delegation_instances_hash
        @delegation_instances
      end

      def name
        "MockSwarm"
      end

      def agent(name)
        @agents[name]
      end

      def agent_definitions
        @agent_defs
      end
    end

    class MockAgentChat
      attr_reader :messages

      def initialize
        @messages = []
      end

      def replace_messages(new_messages)
        @messages.clear
        new_messages.each { |msg| @messages << msg }
        self
      end

      def configure_system_prompt(prompt)
        @messages << RubyLLM::Message.new(role: :system, content: prompt) if prompt
      end

      def agent_context
        @agent_context ||= MockAgentContext.new
      end

      def context_manager
        @context_manager ||= MockContextManager.new
      end

      attr_writer :last_todowrite_message_index

      attr_reader :last_todowrite_message_index

      attr_writer :active_skill_path

      attr_reader :active_skill_path
    end

    class MockAgentContext
      attr_reader :warning_thresholds_hit

      def initialize
        @warning_thresholds_hit = Set.new
      end
    end

    class MockContextManager
      attr_accessor :compression_applied

      def initialize
        @compression_applied = false
      end
    end

    class MockDelegationChat
      attr_reader :messages

      def initialize
        @messages = []
      end

      def replace_messages(new_messages)
        @messages.clear
        new_messages.each { |msg| @messages << msg }
        self
      end

      def configure_system_prompt(prompt)
        @messages << RubyLLM::Message.new(role: :system, content: prompt) if prompt
      end

      def agent_context
        @agent_context ||= MockAgentContext.new
      end

      def context_manager
        @context_manager ||= MockContextManager.new
      end

      attr_writer :last_todowrite_message_index

      attr_reader :last_todowrite_message_index

      attr_writer :active_skill_path

      attr_reader :active_skill_path
    end

    class MockScratchpadStorage
      attr_reader :restored_entries

      def initialize
        @restored_entries = []
      end

      def restore_entries(entries)
        @restored_entries = entries
      end
    end

    class MockReadTracker
      attr_reader :restore_called

      def initialize
        @restore_called = false
      end

      def restore_read_files(agent, files)
        @restore_called = true
      end
    end

    class MockMemoryReadTracker
      attr_reader :restore_called

      def initialize
        @restore_called = false
      end

      def restore_read_entries(agent, entries)
        @restore_called = true
      end
    end

    # Test plugin for plugin state snapshot/restore testing
    class TestStatePlugin < Plugin
      attr_reader :restored_agents, :restored_states, :snapshoted_agents

      def initialize(plugin_name)
        super()
        @plugin_name = plugin_name
        @restored_agents = []
        @restored_states = {}
        @snapshoted_agents = []
        @agent_states = {} # { agent_name => state }
      end

      def name
        @plugin_name
      end

      def tools
        []
      end

      # Set state for an agent (for testing snapshot)
      def set_agent_state(agent_name, state)
        @agent_states[agent_name] = state
      end

      def snapshot_agent_state(agent_name)
        @snapshoted_agents << agent_name
        @agent_states[agent_name] || {}
      end

      def restore_agent_state(agent_name, state)
        @restored_agents << agent_name
        @restored_states[agent_name] = state
      end
    end
  end
end
