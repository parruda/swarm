# frozen_string_literal: true

module SwarmSDK
  module Concerns
    # Shared cleanup functionality for Swarm and Workflow
    #
    # Both classes must have:
    # - mcp_clients: Hash of MCP client arrays
    # - delegation_instances_hash: Hash of delegation instances (via Snapshotable)
    #
    module Cleanupable
      # Cleanup all MCP clients
      #
      # Stops all MCP client connections gracefully.
      # Should be called when the swarm/workflow is no longer needed.
      #
      # @return [void]
      def cleanup
        # Check if there's anything to clean up
        return if @mcp_clients.empty? && (!delegation_instances_hash || delegation_instances_hash.empty?)

        # Stop MCP clients for all agents
        @mcp_clients.each do |agent_name, clients|
          clients.each do |client|
            client.stop
            RubyLLM.logger.debug("SwarmSDK: Stopped MCP client '#{client.name}' for agent #{agent_name}")
          rescue StandardError => e
            RubyLLM.logger.debug("SwarmSDK: Error stopping MCP client '#{client.name}': #{e.message}")
          end
        end

        @mcp_clients.clear

        # Clear delegation instances
        delegation_instances_hash&.clear
      end
    end
  end
end
