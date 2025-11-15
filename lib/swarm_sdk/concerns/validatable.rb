# frozen_string_literal: true

module SwarmSDK
  module Concerns
    # Shared validation functionality for Swarm and Workflow
    #
    # Both classes must have:
    # - agent_definitions: Hash of Agent::Definition objects
    # - swarm_id: Swarm/workflow identifier
    # - parent_swarm_id: Parent identifier (or nil)
    #
    module Validatable
      # Validate swarm/workflow configuration and return warnings
      #
      # This performs lightweight validation checks without creating agents.
      # Useful for displaying configuration warnings before execution.
      #
      # @return [Array<Hash>] Array of warning hashes from all agent definitions
      def validate
        @agent_definitions.flat_map { |_name, definition| definition.validate }
      end

      # Emit validation warnings as log events
      #
      # This validates all agent definitions and emits any warnings as
      # model_lookup_warning events through LogStream. Useful for emitting
      # warnings before execution starts (e.g., in REPL after welcome screen).
      #
      # Requires LogStream.emitter to be set.
      #
      # @return [Array<Hash>] The validation warnings that were emitted
      def emit_validation_warnings
        warnings = validate

        warnings.each do |warning|
          case warning[:type]
          when :model_not_found
            LogStream.emit(
              type: "model_lookup_warning",
              agent: warning[:agent],
              swarm_id: @swarm_id,
              parent_swarm_id: @parent_swarm_id,
              model: warning[:model],
              error_message: warning[:error_message],
              suggestions: warning[:suggestions],
              timestamp: Time.now.utc.iso8601,
            )
          end
        end

        warnings
      end
    end
  end
end
