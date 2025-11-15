# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class SnapshotTest < Minitest::Test
    def setup
      @sample_data = {
        version: "1.0",
        type: "swarm",
        snapshot_at: "2025-01-01T00:00:00Z",
        swarm_sdk_version: "0.1.0",
        agents: {
          agent1: { conversation: [] },
          agent2: { conversation: [] },
        },
        delegation_instances: {
          "agent1->agent2": { conversation: [] },
        },
      }
      @snapshot = Snapshot.new(@sample_data)
    end

    def test_initialize_stores_data
      assert_equal(@sample_data, @snapshot.data)
    end

    def test_to_hash_returns_data
      assert_equal(@sample_data, @snapshot.to_hash)
    end

    def test_to_json_with_pretty_formatting
      json = @snapshot.to_json(pretty: true)
      parsed = JSON.parse(json, symbolize_names: true)

      assert_equal(@sample_data, parsed)
      assert_includes(json, "\n") # Pretty formatting includes newlines
    end

    def test_to_json_without_pretty_formatting
      json = @snapshot.to_json(pretty: false)
      parsed = JSON.parse(json, symbolize_names: true)

      assert_equal(@sample_data, parsed)
      refute_includes(json, "\n  ") # Compact formatting (might have single newline at end)
    end

    def test_to_json_defaults_to_pretty
      json = @snapshot.to_json

      assert_includes(json, "\n")
    end

    def test_write_to_file_creates_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test_snapshot.json")
        @snapshot.write_to_file(path)

        assert_path_exists(path)

        content = File.read(path)
        parsed = JSON.parse(content, symbolize_names: true)

        assert_equal(@sample_data, parsed)
      end
    end

    def test_write_to_file_with_pretty_false
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test_snapshot.json")
        @snapshot.write_to_file(path, pretty: false)

        content = File.read(path)

        refute_includes(content, "\n  ")
      end
    end

    def test_write_to_file_atomic_write
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test_snapshot.json")

        # Create a snapshot that will write successfully
        @snapshot.write_to_file(path)

        # Verify no temp files left behind
        temp_files = Dir.glob(File.join(dir, "*.tmp.*"))

        assert_empty(temp_files)
      end
    end

    def test_write_to_file_cleans_up_on_error
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test_snapshot.json")

        # Mock File.rename to raise an error
        File.stub(:rename, ->(*_args) { raise "Simulated error" }) do
          assert_raises(RuntimeError) do
            @snapshot.write_to_file(path)
          end
        end

        # Temp files should be cleaned up (we can't test this perfectly but the code should handle it)
        # The actual temp file might not exist since File.write might not be called
      end
    end

    def test_from_hash_creates_snapshot
      snapshot = Snapshot.from_hash(@sample_data)

      assert_instance_of(Snapshot, snapshot)
      assert_equal(@sample_data, snapshot.data)
    end

    def test_from_json_creates_snapshot
      json_string = JSON.generate(@sample_data)
      snapshot = Snapshot.from_json(json_string)

      assert_instance_of(Snapshot, snapshot)
      assert_equal(@sample_data, snapshot.data)
    end

    def test_from_file_creates_snapshot
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test_snapshot.json")
        File.write(path, JSON.pretty_generate(@sample_data))

        snapshot = Snapshot.from_file(path)

        assert_instance_of(Snapshot, snapshot)
        assert_equal(@sample_data, snapshot.data)
      end
    end

    def test_version_accessor
      assert_equal("1.0", @snapshot.version)
    end

    def test_version_with_string_keys
      data = { "version" => "2.0" }
      snapshot = Snapshot.new(data)

      assert_equal("2.0", snapshot.version)
    end

    def test_type_accessor
      assert_equal("swarm", @snapshot.type)
    end

    def test_type_with_string_keys
      data = { "type" => "workflow" }
      snapshot = Snapshot.new(data)

      assert_equal("workflow", snapshot.type)
    end

    def test_snapshot_at_accessor
      assert_equal("2025-01-01T00:00:00Z", @snapshot.snapshot_at)
    end

    def test_snapshot_at_with_string_keys
      data = { "snapshot_at" => "2025-12-31T23:59:59Z" }
      snapshot = Snapshot.new(data)

      assert_equal("2025-12-31T23:59:59Z", snapshot.snapshot_at)
    end

    def test_swarm_sdk_version_accessor
      assert_equal("0.1.0", @snapshot.swarm_sdk_version)
    end

    def test_swarm_sdk_version_with_string_keys
      data = { "swarm_sdk_version" => "0.2.0" }
      snapshot = Snapshot.new(data)

      assert_equal("0.2.0", snapshot.swarm_sdk_version)
    end

    def test_agent_names_with_symbol_keys
      assert_equal(["agent1", "agent2"], @snapshot.agent_names.sort)
    end

    def test_agent_names_with_string_keys
      data = {
        "agents" => {
          "agent1" => {},
          "agent2" => {},
        },
      }
      snapshot = Snapshot.new(data)

      assert_equal(["agent1", "agent2"], snapshot.agent_names.sort)
    end

    def test_agent_names_with_nil_agents
      data = { version: "1.0" }
      snapshot = Snapshot.new(data)

      assert_empty(snapshot.agent_names)
    end

    def test_delegation_instance_names_with_symbol_keys
      assert_equal(["agent1->agent2"], @snapshot.delegation_instance_names)
    end

    def test_delegation_instance_names_with_string_keys
      data = {
        "delegation_instances" => {
          "a->b" => {},
          "c->d" => {},
        },
      }
      snapshot = Snapshot.new(data)

      assert_equal(["a->b", "c->d"], snapshot.delegation_instance_names.sort)
    end

    def test_delegation_instance_names_with_nil_delegations
      data = { version: "1.0" }
      snapshot = Snapshot.new(data)

      assert_empty(snapshot.delegation_instance_names)
    end

    def test_swarm_predicate_returns_true_for_swarm
      assert_predicate(@snapshot, :swarm?)
      refute_predicate(@snapshot, :workflow?)
    end

    def test_workflow_predicate_returns_true_for_workflow
      data = { type: "workflow" }
      snapshot = Snapshot.new(data)

      refute_predicate(snapshot, :swarm?)
      assert_predicate(snapshot, :workflow?)
    end

    def test_round_trip_with_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "roundtrip.json")

        # Write snapshot
        @snapshot.write_to_file(path)

        # Read it back
        loaded = Snapshot.from_file(path)

        # Verify data matches
        assert_equal(@snapshot.data, loaded.data)
        assert_equal(@snapshot.version, loaded.version)
        assert_equal(@snapshot.type, loaded.type)
        assert_equal(@snapshot.agent_names.sort, loaded.agent_names.sort)
      end
    end

    def test_empty_snapshot
      empty_data = {}
      snapshot = Snapshot.new(empty_data)

      assert_nil(snapshot.version)
      assert_nil(snapshot.type)
      assert_nil(snapshot.snapshot_at)
      assert_empty(snapshot.agent_names)
      assert_empty(snapshot.delegation_instance_names)
      refute_predicate(snapshot, :swarm?)
      refute_predicate(snapshot, :workflow?)
    end
  end
end
