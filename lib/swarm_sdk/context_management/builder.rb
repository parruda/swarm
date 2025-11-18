# frozen_string_literal: true

module SwarmSDK
  module ContextManagement
    # DSL for defining context management handlers
    #
    # This builder provides a clean, idiomatic way to register handlers for
    # context warning thresholds. Handlers receive a rich context object
    # with message manipulation methods.
    #
    # @example Basic usage
    #   context_management do
    #     on :warning_60 do |ctx|
    #       ctx.compress_tool_results(keep_recent: 10)
    #     end
    #
    #     on :warning_80 do |ctx|
    #       ctx.prune_old_messages(keep_recent: 20)
    #     end
    #   end
    #
    # @example Progressive compression
    #   context_management do
    #     on :warning_60 do |ctx|
    #       ctx.compress_tool_results(keep_recent: 15, truncate_to: 500)
    #     end
    #
    #     on :warning_80 do |ctx|
    #       ctx.prune_old_messages(keep_recent: 30)
    #       ctx.compress_tool_results(keep_recent: 5, truncate_to: 200)
    #     end
    #
    #     on :warning_90 do |ctx|
    #       ctx.log_action("emergency_pruning", tokens_remaining: ctx.tokens_remaining)
    #       ctx.prune_old_messages(keep_recent: 15)
    #     end
    #   end
    class Builder
      # Map semantic event names to threshold percentages
      EVENT_MAP = {
        warning_60: 60,
        warning_80: 80,
        warning_90: 90,
      }.freeze

      def initialize
        @handlers = {} # { threshold => block }
      end

      # Register a handler for a context warning threshold
      #
      # Handlers take full responsibility for managing context at their threshold.
      # When a handler is registered for a threshold, automatic compression is disabled
      # for that threshold.
      #
      # @param event [Symbol] Event name (:warning_60, :warning_80, :warning_90)
      # @yield [ContextManagement::Context] Context with message manipulation methods
      # @return [void]
      #
      # @raise [ArgumentError] If event is unknown or block is missing
      #
      # @example Compress tool results at 60%
      #   on :warning_60 do |ctx|
      #     ctx.compress_tool_results(keep_recent: 10)
      #   end
      #
      # @example Custom logic at 80%
      #   on :warning_80 do |ctx|
      #     if ctx.usage_percentage > 85
      #       ctx.prune_old_messages(keep_recent: 10)
      #     else
      #       ctx.summarize_old_exchanges(older_than: 20)
      #     end
      #   end
      #
      # @example Log and prune at 90%
      #   on :warning_90 do |ctx|
      #     ctx.log_action("critical_threshold", remaining: ctx.tokens_remaining)
      #     ctx.prune_old_messages(keep_recent: 10)
      #   end
      def on(event, &block)
        threshold = EVENT_MAP[event]
        raise ArgumentError, "Unknown event: #{event}. Valid events: #{EVENT_MAP.keys.join(", ")}" unless threshold
        raise ArgumentError, "Block required for #{event}" unless block

        @handlers[threshold] = block
      end

      # Build hook definitions from handlers
      #
      # Creates Hooks::Definition objects that wrap user blocks to provide
      # rich context objects instead of raw Hooks::Context. Each handler
      # becomes a hook for the :context_warning event.
      #
      # @return [Array<Hooks::Definition>] Hook definitions for :context_warning event
      def build
        @handlers.map do |threshold, user_block|
          # Create a hook that filters by threshold and wraps context
          Hooks::Definition.new(
            event: :context_warning,
            matcher: nil, # No tool matching needed
            priority: 0,
            proc: create_threshold_matcher(threshold, user_block),
          )
        end
      end

      private

      # Create a proc that matches threshold and wraps context
      #
      # @param target_threshold [Integer] Threshold to match (60, 80, 90)
      # @param user_block [Proc] User's handler block
      # @return [Proc] Hook proc
      def create_threshold_matcher(target_threshold, user_block)
        proc do |hooks_context|
          # Only execute for matching threshold
          current_threshold = hooks_context.metadata[:threshold]
          next unless current_threshold == target_threshold

          # Wrap in rich context object
          rich_context = Context.new(hooks_context)
          user_block.call(rich_context)
        end
      end
    end
  end
end
