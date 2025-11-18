# frozen_string_literal: true

module SwarmSDK
  module Agent
    # AgentContext encapsulates per-agent state and metadata
    #
    # Each agent has its own context that tracks:
    # - Agent identity (name)
    # - Delegation relationships (which tool calls are delegations)
    # - Context window warnings (which thresholds have been hit)
    # - Optional metadata
    #
    # This class replaces the per-agent hash maps that were previously
    # stored in UnifiedLogger.
    #
    # @example
    #   context = Agent::Context.new(
    #     name: :backend,
    #     delegation_tools: ["DelegateToDatabase", "DelegateToAuth"],
    #     metadata: { role: "backend" }
    #   )
    #
    #   # Track a delegation
    #   context.track_delegation(call_id: "call_123", target: "DelegateToDatabase")
    #
    #   # Check if a tool call is a delegation
    #   context.delegation?(call_id: "call_123") # => true
    class Context
      # Thresholds for context limit warnings (in percentage)
      # 60% triggers automatic compression, 80%/90% are informational warnings
      CONTEXT_WARNING_THRESHOLDS = [60, 80, 90].freeze

      # Backward compatibility alias - use Defaults module for new code
      COMPRESSION_THRESHOLD = Defaults::Context::COMPRESSION_THRESHOLD_PERCENT

      attr_reader :name, :delegation_tools, :metadata, :warning_thresholds_hit, :swarm_id, :parent_swarm_id

      # Initialize a new agent context
      #
      # @param name [Symbol, String] Agent name
      # @param swarm_id [String] Swarm ID for event tracking
      # @param parent_swarm_id [String, nil] Parent swarm ID (nil for root swarms)
      # @param delegation_tools [Array<String>] Names of tools that are delegations
      # @param metadata [Hash] Optional metadata about the agent
      def initialize(name:, swarm_id:, parent_swarm_id: nil, delegation_tools: [], metadata: {})
        @name = name.to_sym
        @swarm_id = swarm_id
        @parent_swarm_id = parent_swarm_id
        @delegation_tools = Set.new(delegation_tools.map(&:to_s))
        @metadata = metadata
        @delegation_call_ids = Set.new
        @delegation_targets = {}
        @warning_thresholds_hit = Set.new
      end

      # Track a delegation tool call
      #
      # @param call_id [String] Tool call ID
      # @param target [String] Target agent/tool name
      # @return [void]
      def track_delegation(call_id:, target:)
        @delegation_call_ids.add(call_id)
        @delegation_targets[call_id] = target
      end

      # Check if a tool call is a delegation
      #
      # @param call_id [String] Tool call ID
      # @return [Boolean]
      def delegation?(call_id:)
        @delegation_call_ids.include?(call_id)
      end

      # Get the delegation target for a tool call
      #
      # @param call_id [String] Tool call ID
      # @return [String, nil] Target agent/tool name, or nil if not a delegation
      def delegation_target(call_id:)
        @delegation_targets[call_id]
      end

      # Remove a delegation from tracking (after it completes)
      #
      # @param call_id [String] Tool call ID
      # @return [void]
      def clear_delegation(call_id:)
        @delegation_targets.delete(call_id)
        @delegation_call_ids.delete(call_id)
      end

      # Check if a tool name is a delegation tool
      #
      # @param tool_name [String] Tool name
      # @return [Boolean]
      def delegation_tool?(tool_name)
        @delegation_tools.include?(tool_name.to_s)
      end

      # Record that a context warning threshold has been hit
      #
      # @param threshold [Integer] Threshold percentage (80, 90, etc)
      # @return [Boolean] true if this is the first time hitting this threshold
      def hit_warning_threshold?(threshold)
        !@warning_thresholds_hit.add?(threshold).nil?
      end

      # Check if a warning threshold has been hit
      #
      # @param threshold [Integer] Threshold percentage
      # @return [Boolean]
      def warning_threshold_hit?(threshold)
        @warning_thresholds_hit.include?(threshold)
      end
    end
  end
end
