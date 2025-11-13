# frozen_string_literal: true

module SwarmSDK
  module Concerns
    # Shared snapshot and restore functionality for Swarm and Workflow
    #
    # Both classes must implement:
    # - primary_agents: Returns hash of primary agent instances
    # - delegation_instances_hash: Returns hash of delegation instances
    # - agent_definitions: Returns hash of agent definitions
    # - swarm_id: Returns the swarm/workflow ID
    # - parent_swarm_id: Returns the parent ID (or nil)
    # - name: Returns the swarm/workflow name
    #
    module Snapshotable
      # Create snapshot of current conversation state
      #
      # Returns a Snapshot object containing:
      # - All agent conversations (@messages arrays)
      # - Agent context state (warnings, compression, TodoWrite tracking, skills)
      # - Delegation instance conversations
      # - Scratchpad contents (volatile shared storage)
      # - Read tracking state (which files each agent has read with digests)
      # - Memory read tracking state (which memory entries each agent has read with digests)
      #
      # @return [Snapshot] Snapshot object with convenient serialization methods
      def snapshot
        StateSnapshot.new(self).snapshot
      end

      # Restore conversation state from snapshot
      #
      # Accepts a Snapshot object, hash, or JSON string. Validates compatibility
      # between snapshot and current configuration, restores agent conversations,
      # context state, scratchpad, and read tracking.
      #
      # The swarm/workflow must be created with the SAME configuration (agent definitions,
      # tools, prompts) as when the snapshot was created. Only conversation state
      # is restored from the snapshot.
      #
      # @param snapshot [Snapshot, Hash, String] Snapshot object, hash, or JSON string
      # @param preserve_system_prompts [Boolean] Use historical system prompts instead of current config (default: false)
      # @return [RestoreResult] Result with warnings about skipped agents
      def restore(snapshot, preserve_system_prompts: false)
        StateRestorer.new(self, snapshot, preserve_system_prompts: preserve_system_prompts).restore
      end

      # Interface method: Get primary agent instances
      #
      # Must be implemented by including class.
      #
      # @return [Hash<Symbol, Agent::Chat>] Primary agent instances
      def primary_agents
        raise NotImplementedError, "#{self.class} must implement #primary_agents"
      end

      # Interface method: Get delegation instance hash
      #
      # Must be implemented by including class.
      #
      # @return [Hash<String, Agent::Chat>] Delegation instances with keys like "delegate@delegator"
      def delegation_instances_hash
        raise NotImplementedError, "#{self.class} must implement #delegation_instances_hash"
      end
    end
  end
end
