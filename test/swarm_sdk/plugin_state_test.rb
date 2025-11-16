# frozen_string_literal: true

require "test_helper"
require_relative "test_helper"

module SwarmSDK
  class PluginStateTest < Minitest::Test
    def setup
      @original_plugins = PluginRegistry.all.dup
      PluginRegistry.clear
    end

    def teardown
      PluginRegistry.clear
      # Restore original plugins
      @original_plugins.each { |p| PluginRegistry.register(p) }
    end

    # ========== Plugin Base Class Default Behavior ==========

    def test_plugin_base_snapshot_agent_state_returns_empty_hash
      plugin = Plugin.new

      result = plugin.snapshot_agent_state(:test_agent)

      assert_empty(result)
    end

    def test_plugin_base_restore_agent_state_does_nothing
      plugin = Plugin.new

      # Should not raise - base implementation is a no-op
      result = plugin.restore_agent_state(:test_agent, { some: "state" })

      # Base implementation returns nil (no-op)
      assert_nil(result)
    end

    def test_plugin_snapshot_agent_state_can_be_overridden
      plugin = TrackingStatePlugin.new(:test)
      plugin.setup_state(:alice, { key: "value" })

      result = plugin.snapshot_agent_state(:alice)

      assert_equal({ key: "value" }, result)
    end

    def test_plugin_restore_agent_state_can_be_overridden
      plugin = TrackingStatePlugin.new(:test)

      plugin.restore_agent_state(:alice, { key: "value" })

      assert_includes(plugin.restored_agents, :alice)
      assert_equal({ key: "value" }, plugin.restored_states[:alice])
    end

    # ========== StateSnapshot Plugin State Integration ==========

    def test_snapshot_creates_plugin_states_structure
      swarm = create_mock_swarm_with_agents([:alice])
      plugin = TrackingStatePlugin.new(:memory)
      plugin.setup_state(:alice, { read_entries: { "/entry" => "digest" } })
      PluginRegistry.register(plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot

      assert_includes(snapshot.to_hash.keys, :plugin_states)
    end

    def test_snapshot_version_is_210
      swarm = create_mock_swarm_with_agents([:alice])
      snapshotter = StateSnapshot.new(swarm)

      snapshot = snapshotter.snapshot

      assert_equal("2.1.0", snapshot.to_hash[:version])
    end

    def test_snapshot_includes_plugin_state_for_agent
      swarm = create_mock_swarm_with_agents([:alice])
      plugin = TrackingStatePlugin.new(:memory)
      plugin.setup_state(:alice, { read_entries: { "/entry1" => "digest1" } })
      PluginRegistry.register(plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]

      assert_equal(
        { "memory" => { "alice" => { read_entries: { "/entry1" => "digest1" } } } },
        plugin_states,
      )
    end

    def test_snapshot_includes_multiple_plugins
      swarm = create_mock_swarm_with_agents([:alice])
      memory_plugin = TrackingStatePlugin.new(:memory)
      memory_plugin.setup_state(:alice, { read_entries: { "/m" => "d1" } })
      custom_plugin = TrackingStatePlugin.new(:custom)
      custom_plugin.setup_state(:alice, { custom: "data" })
      PluginRegistry.register(memory_plugin)
      PluginRegistry.register(custom_plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]

      assert_equal(2, plugin_states.size)
      assert_includes(plugin_states.keys, "memory")
      assert_includes(plugin_states.keys, "custom")
    end

    def test_snapshot_includes_multiple_agents
      swarm = create_mock_swarm_with_agents([:alice, :bob])
      plugin = TrackingStatePlugin.new(:memory)
      plugin.setup_state(:alice, { read_entries: { "/a" => "da" } })
      plugin.setup_state(:bob, { read_entries: { "/b" => "db" } })
      PluginRegistry.register(plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]["memory"]

      assert_includes(plugin_states.keys, "alice")
      assert_includes(plugin_states.keys, "bob")
    end

    def test_snapshot_omits_plugins_with_empty_state
      swarm = create_mock_swarm_with_agents([:alice])
      plugin = TrackingStatePlugin.new(:memory)
      # No state setup - will return empty hash
      PluginRegistry.register(plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]

      # Should not include plugin with no state
      refute_includes(plugin_states.keys, "memory")
    end

    def test_snapshot_omits_agents_with_empty_state
      swarm = create_mock_swarm_with_agents([:alice, :bob])
      plugin = TrackingStatePlugin.new(:memory)
      plugin.setup_state(:alice, { read_entries: { "/a" => "da" } })
      # bob has no state
      PluginRegistry.register(plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]["memory"]

      assert_includes(plugin_states.keys, "alice")
      refute_includes(plugin_states.keys, "bob")
    end

    def test_snapshot_includes_delegation_instances
      swarm = create_mock_swarm_with_agents([:alice])
      # Add a delegation instance
      swarm.delegation_instances["bob@alice".to_sym] = MockAgentChat.new
      plugin = TrackingStatePlugin.new(:memory)
      plugin.setup_state(:"bob@alice", { read_entries: { "/d" => "dd" } })
      PluginRegistry.register(plugin)

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]["memory"]

      assert_includes(plugin_states.keys, "bob@alice")
    end

    def test_snapshot_no_registered_plugins_returns_empty_hash
      swarm = create_mock_swarm_with_agents([:alice])
      # No plugins registered

      snapshotter = StateSnapshot.new(swarm)
      snapshot = snapshotter.snapshot
      plugin_states = snapshot.to_hash[:plugin_states]

      assert_empty(plugin_states)
    end

    private

    def create_mock_swarm_with_agents(agent_names)
      MockSwarmForSnapshot.new(agent_names)
    end

    # Mock swarm with minimal interface for StateSnapshot
    class MockSwarmForSnapshot
      attr_reader :delegation_instances, :swarm_id, :parent_swarm_id

      # Override class name for type detection
      class << self
        def name
          "SwarmSDK::Swarm"
        end
      end

      def initialize(agent_names)
        @agent_names = agent_names
        @agent_defs = {}
        @agents = {}
        @delegation_instances = {}
        @swarm_id = nil
        @parent_swarm_id = nil

        agent_names.each do |name|
          @agent_defs[name] = MockAgentDef.new("Test prompt for #{name}")
          @agents[name] = MockAgentChat.new
        end
      end

      def primary_agents
        @agents
      end

      def delegation_instances_hash
        @delegation_instances
      end

      def agent_definitions
        @agent_defs
      end

      def first_message_sent?
        false
      end

      def name
        "MockSwarm"
      end

      def scratchpad_storage
        nil
      end
    end

    class MockAgentDef
      attr_reader :system_prompt

      def initialize(system_prompt)
        @system_prompt = system_prompt
      end
    end

    class MockAgentChat
      def messages
        []
      end

      def agent_context
        @agent_context ||= MockAgentContext.new
      end

      def context_manager
        @context_manager ||= MockContextManager.new
      end

      def last_todowrite_message_index
        nil
      end

      def active_skill_path
        nil
      end
    end

    class MockAgentContext
      def warning_thresholds_hit
        @warning_thresholds_hit ||= Set.new
      end
    end

    class MockContextManager
      attr_reader :compression_applied

      def initialize
        @compression_applied = false
      end
    end

    # Plugin that tracks snapshot/restore calls
    class TrackingStatePlugin < Plugin
      attr_reader :restored_agents, :restored_states, :snapshotted_agents

      def initialize(plugin_name)
        super()
        @plugin_name = plugin_name
        @restored_agents = []
        @restored_states = {}
        @snapshotted_agents = []
        @agent_states = {}
      end

      def name
        @plugin_name
      end

      def tools
        []
      end

      def setup_state(agent_name, state)
        @agent_states[agent_name] = state
      end

      def snapshot_agent_state(agent_name)
        @snapshotted_agents << agent_name
        @agent_states[agent_name] || {}
      end

      def restore_agent_state(agent_name, state)
        @restored_agents << agent_name
        @restored_states[agent_name] = state
      end
    end
  end
end
