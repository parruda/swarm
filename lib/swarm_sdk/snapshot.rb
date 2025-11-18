# frozen_string_literal: true

module SwarmSDK
  # Snapshot of swarm conversation state
  #
  # Encapsulates snapshot data with methods for serialization and deserialization.
  # Provides a clean API for saving/loading snapshots in various formats.
  #
  # @example Create and save snapshot
  #   snapshot = swarm.snapshot
  #   snapshot.write_to_file("session.json")
  #
  # @example Load and restore snapshot
  #   snapshot = SwarmSDK::Snapshot.from_file("session.json")
  #   result = swarm.restore(snapshot)
  #
  # @example Convert to/from hash
  #   hash = snapshot.to_hash
  #   snapshot = SwarmSDK::Snapshot.from_hash(hash)
  class Snapshot
    attr_reader :data

    # Initialize snapshot with data
    #
    # @param data [Hash] Snapshot data hash
    def initialize(data)
      @data = data
    end

    # Convert snapshot to hash
    #
    # @return [Hash] Snapshot data as hash
    def to_hash
      @data
    end

    # Convert snapshot to JSON string
    #
    # @param pretty [Boolean] Whether to pretty-print JSON (default: true)
    # @return [String] JSON string
    def to_json(pretty: true)
      if pretty
        JSON.pretty_generate(@data)
      else
        JSON.generate(@data)
      end
    end

    # Write snapshot to file as JSON
    #
    # Uses atomic write pattern (write to temp file, then rename) to prevent
    # corruption if process crashes during write.
    #
    # @param path [String] File path to write to
    # @param pretty [Boolean] Whether to pretty-print JSON (default: true)
    # @return [void]
    def write_to_file(path, pretty: true)
      # Atomic write: write to temp file, then rename
      # This ensures the snapshot file is never corrupted even if process crashes
      temp_path = "#{path}.tmp.#{Process.pid}.#{Time.now.to_i}.#{SecureRandom.hex(4)}"

      File.write(temp_path, to_json(pretty: pretty))
      File.rename(temp_path, path)
    rescue
      # Clean up temp file if it exists
      File.delete(temp_path) if File.exist?(temp_path)
      raise
    end

    class << self
      # Create snapshot from hash
      #
      # @param hash [Hash] Snapshot data hash
      # @return [Snapshot] New snapshot instance
      def from_hash(hash)
        new(hash)
      end

      # Create snapshot from JSON string
      #
      # @param json_string [String] JSON string
      # @return [Snapshot] New snapshot instance
      def from_json(json_string)
        hash = JSON.parse(json_string, symbolize_names: true)
        new(hash)
      end

      # Create snapshot from JSON file
      #
      # @param path [String] File path to read from
      # @return [Snapshot] New snapshot instance
      def from_file(path)
        json_string = File.read(path)
        from_json(json_string)
      end
    end

    # Get snapshot version
    #
    # @return [String] Snapshot version
    def version
      @data[:version] || @data["version"]
    end

    # Get snapshot type (swarm or workflow)
    #
    # @return [String] Snapshot type
    def type
      @data[:type] || @data["type"]
    end

    # Get timestamp when snapshot was created
    #
    # @return [String] ISO8601 timestamp
    def snapshot_at
      @data[:snapshot_at] || @data["snapshot_at"]
    end

    # Get SwarmSDK version that created this snapshot
    #
    # @return [String] SwarmSDK version
    def swarm_sdk_version
      @data[:swarm_sdk_version] || @data["swarm_sdk_version"]
    end

    # Get agent names from snapshot
    #
    # @return [Array<String>] Agent names
    def agent_names
      agents = @data[:agents] || @data["agents"]
      agents ? agents.keys.map(&:to_s) : []
    end

    # Get delegation instance names from snapshot
    #
    # @return [Array<String>] Delegation instance names
    def delegation_instance_names
      delegations = @data[:delegation_instances] || @data["delegation_instances"]
      delegations ? delegations.keys.map(&:to_s) : []
    end

    # Check if snapshot is for a swarm (vs workflow)
    #
    # @return [Boolean] true if swarm snapshot
    def swarm?
      type == "swarm"
    end

    # Check if snapshot is for a workflow
    #
    # @return [Boolean] true if workflow snapshot
    def workflow?
      type == "workflow"
    end
  end
end
