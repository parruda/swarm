# frozen_string_literal: true

module SwarmSDK
  module ContextManagement
    # Rich context wrapper for context management handlers
    #
    # Provides a clean, developer-friendly API for manipulating the conversation
    # context when warning thresholds are triggered. Wraps the lower-level
    # Hooks::Context with message manipulation helpers.
    #
    # @example Basic usage in handler
    #   on :warning_60 do |ctx|
    #     ctx.compress_tool_results(keep_recent: 10)
    #   end
    #
    # @example Advanced usage with metrics
    #   on :warning_80 do |ctx|
    #     if ctx.usage_percentage > 85
    #       ctx.prune_old_messages(keep_recent: 10)
    #       ctx.log_action("aggressive_pruning", remaining: ctx.tokens_remaining)
    #     else
    #       ctx.compress_tool_results(keep_recent: 5, truncate_to: 100)
    #     end
    #   end
    class Context
      # Create a new context wrapper
      #
      # @param hooks_context [Hooks::Context] Lower-level hook context with metadata
      def initialize(hooks_context)
        @hooks_context = hooks_context
        @chat = hooks_context.metadata[:chat]
      end

      # --- Context Metrics ---

      # Current context usage percentage
      #
      # @return [Float] Usage percentage (0.0 to 100.0)
      #
      # @example
      #   if ctx.usage_percentage > 85
      #     ctx.prune_old_messages(keep_recent: 10)
      #   end
      def usage_percentage
        @hooks_context.metadata[:percentage]
      end

      # Threshold that triggered this handler
      #
      # @return [Integer] Threshold (60, 80, or 90)
      #
      # @example
      #   ctx.log_action("threshold_hit", threshold: ctx.threshold)
      def threshold
        @hooks_context.metadata[:threshold]
      end

      # Total tokens used so far
      #
      # @return [Integer] Token count
      #
      # @example
      #   ctx.log_action("usage", tokens: ctx.tokens_used)
      def tokens_used
        @hooks_context.metadata[:tokens_used]
      end

      # Tokens remaining in context window
      #
      # @return [Integer] Token count
      #
      # @example
      #   if ctx.tokens_remaining < 10000
      #     ctx.prune_old_messages(keep_recent: 5)
      #   end
      def tokens_remaining
        @hooks_context.metadata[:tokens_remaining]
      end

      # Total context window size
      #
      # @return [Integer] Token count
      #
      # @example
      #   buffer = ctx.context_limit * 0.1  # 10% buffer
      def context_limit
        @hooks_context.metadata[:context_limit]
      end

      # Agent name
      #
      # @return [Symbol] Agent identifier
      #
      # @example
      #   ctx.log_action("agent_context", agent: ctx.agent_name)
      def agent_name
        @hooks_context.agent_name
      end

      # --- Message Access ---

      # Get all messages (copy for manipulation)
      #
      # @return [Array<RubyLLM::Message>] Message array
      #
      # @example
      #   ctx.messages.each do |msg|
      #     puts "#{msg.role}: #{msg.content.length} chars"
      #   end
      def messages
        @chat.messages
      end

      # Number of messages
      #
      # @return [Integer] Message count
      #
      # @example
      #   if ctx.message_count > 100
      #     ctx.prune_old_messages(keep_recent: 50)
      #   end
      def message_count
        @chat.message_count
      end

      # --- Message Manipulation ---

      # Replace all messages with new array
      #
      # @param new_messages [Array<RubyLLM::Message>] New message array
      # @return [void]
      #
      # @example
      #   new_msgs = ctx.messages.reject { |m| m.role == :tool }
      #   ctx.replace_messages(new_msgs)
      def replace_messages(new_messages)
        @chat.replace_messages(new_messages)
      end

      # Compress tool result messages to save context space
      #
      # Creates NEW message objects with truncated content (follows RubyLLM patterns).
      # Truncates old tool results while keeping recent ones intact.
      # Automatically marks compression as applied to prevent double compression.
      #
      # @param keep_recent [Integer] Number of recent tool results to preserve (default: 10)
      # @param truncate_to [Integer] Max characters for truncated results (default: 200)
      # @return [Integer] Number of messages compressed
      #
      # @example Light compression at 60%
      #   ctx.compress_tool_results(keep_recent: 15, truncate_to: 500)
      #
      # @example Aggressive compression at 80%
      #   ctx.compress_tool_results(keep_recent: 5, truncate_to: 100)
      def compress_tool_results(keep_recent: 10, truncate_to: 200)
        msgs = messages.dup
        compressed_count = 0

        # Find tool result messages (skip recent ones)
        tool_indices = []
        msgs.each_with_index do |msg, idx|
          tool_indices << idx if msg.role == :tool
        end

        # Keep recent tool results, compress older ones
        indices_to_compress = tool_indices[0...-keep_recent] || []

        indices_to_compress.each do |idx|
          msg = msgs[idx]
          content = msg.content.to_s
          next if content.length <= truncate_to

          # Create NEW message with truncated content (NO instance_variable_set!)
          truncated_content = "#{content[0...truncate_to]}... [truncated for context management]"

          # Create new message object following RubyLLM patterns
          msgs[idx] = RubyLLM::Message.new(
            role: :tool,
            content: truncated_content,
            tool_call_id: msg.tool_call_id,
          )
          compressed_count += 1
        end

        replace_messages(msgs)

        # Mark compression as applied to coordinate with ContextManager
        mark_compression_applied

        compressed_count
      end

      # Mark compression as applied in ContextManager
      #
      # Call this when your handler performs compression to prevent
      # double compression from auto-compression logic.
      #
      # @return [void]
      #
      # @example Custom compression
      #   msgs = ctx.messages.map { |m| ... } # custom logic
      #   ctx.replace_messages(msgs)
      #   ctx.mark_compression_applied
      def mark_compression_applied
        return unless @chat.respond_to?(:context_manager)

        @chat.context_manager.compression_applied = true
      end

      # Check if compression has already been applied
      #
      # @return [Boolean] True if compression was already applied
      #
      # @example Conditional compression
      #   unless ctx.compression_applied?
      #     ctx.compress_tool_results(keep_recent: 10)
      #   end
      def compression_applied?
        return false unless @chat.respond_to?(:context_manager)

        !!@chat.context_manager.compression_applied
      end

      # Remove old messages from history
      #
      # Keeps system message (if any) and recent exchanges.
      # This is more aggressive than compression and loses context.
      #
      # @param keep_recent [Integer] Number of recent messages to keep (default: 20)
      # @return [Integer] Number of messages removed
      #
      # @example Prune at 80% threshold
      #   ctx.prune_old_messages(keep_recent: 30)
      #
      # @example Emergency pruning at 90%
      #   ctx.prune_old_messages(keep_recent: 10)
      def prune_old_messages(keep_recent: 20)
        msgs = messages.dup
        original_count = msgs.size

        # Always keep system message if present
        system_msg = msgs.first if msgs.first&.role == :system
        non_system = system_msg ? msgs[1..] : msgs

        # Keep only recent messages
        if non_system.size > keep_recent
          kept = non_system.last(keep_recent)
          new_msgs = system_msg ? [system_msg] + kept : kept
          replace_messages(new_msgs)
          original_count - new_msgs.size
        else
          0
        end
      end

      # Summarize old message exchanges
      #
      # Groups old user/assistant pairs and replaces with summary.
      # This is a placeholder - actual implementation would use LLM.
      #
      # @param older_than [Integer] Messages older than this index get summarized
      # @return [Integer] Number of exchanges summarized
      #
      # @example
      #   ctx.summarize_old_exchanges(older_than: 10)
      def summarize_old_exchanges(older_than: 10)
        # For now, this is a marker - full implementation would call LLM
        # to summarize exchanges. We provide the API for developers to
        # implement their own summarization logic.
        0
      end

      # Custom message transformation
      #
      # Apply a block to transform messages. This gives full control
      # over message manipulation for custom strategies.
      #
      # @yield [Array<RubyLLM::Message>] Current messages
      # @yieldreturn [Array<RubyLLM::Message>] Transformed messages
      # @return [void]
      #
      # @example Remove specific tool results
      #   ctx.transform_messages do |msgs|
      #     msgs.reject { |m| m.role == :tool && m.content.include?("verbose output") }
      #   end
      #
      # @example Custom compression logic
      #   ctx.transform_messages do |msgs|
      #     msgs.map do |m|
      #       if m.role == :tool && m.content.length > 1000
      #         RubyLLM::Message.new(role: :tool, content: m.content[0..500], tool_call_id: m.tool_call_id)
      #       else
      #         m
      #       end
      #     end
      #   end
      def transform_messages
        new_msgs = yield(messages.dup)
        replace_messages(new_msgs)
      end

      # Log a context management action
      #
      # Emits a log event for tracking what actions were taken.
      # Useful for debugging and monitoring context management strategies.
      #
      # @param action [String] Description of action taken
      # @param details [Hash] Additional details
      # @return [void]
      #
      # @example Log compression action
      #   ctx.log_action("compressed_tool_results", count: 5)
      #
      # @example Log emergency action
      #   ctx.log_action("emergency_pruning", remaining: ctx.tokens_remaining)
      def log_action(action, details = {})
        LogStream.emit(
          type: "context_management_action",
          agent: agent_name,
          threshold: threshold,
          action: action,
          usage_percentage: usage_percentage,
          **details,
        )
      end
    end
  end
end
