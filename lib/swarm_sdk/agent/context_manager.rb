# frozen_string_literal: true

module SwarmSDK
  module Agent
    # Manages conversation context and message optimization
    #
    # Responsibilities:
    # - Handle ephemeral messages (sent to LLM but not persisted)
    # - Extract and strip system reminders
    # - Prepare messages for LLM API calls
    # - Future: Context window management, summarization, truncation
    #
    # @example
    #   manager = ContextManager.new
    #   manager.add_ephemeral_reminder("<system-reminder>Use caution</system-reminder>")
    #   messages_for_llm = manager.prepare_for_llm(persistent_messages)
    #   manager.clear_ephemeral  # After LLM call
    class ContextManager
      SYSTEM_REMINDER_REGEX = %r{<system-reminder>.*?</system-reminder>}m

      # Expose compression state for snapshot/restore
      # NOTE: @compression_applied initializes to nil (not false), only set to true when compression runs
      attr_reader :compression_applied
      attr_writer :compression_applied

      def initialize
        # Ephemeral content to append to messages for this turn only
        # Format: { message_index => [array of reminder strings] }
        @ephemeral_content = {}
        # NOTE: @compression_applied is NOT initialized here - starts as nil
      end

      # Track ephemeral content to append to a specific message
      #
      # Reminders will be embedded in the message content when sent to LLM,
      # but are NOT persisted in the message history.
      #
      # @param message_index [Integer] Index of message to append to
      # @param content [String] Reminder content to append
      # @return [void]
      def add_ephemeral_content_for_message(message_index, content)
        @ephemeral_content[message_index] ||= []
        @ephemeral_content[message_index] << content
      end

      # Add ephemeral reminder to the most recent message
      #
      # This will append the reminder to the last message in the array when
      # preparing for LLM, but won't modify the stored message.
      #
      # @param content [String] Reminder content
      # @param messages_array [Array<RubyLLM::Message>] Message array to get index from
      # @return [void]
      def add_ephemeral_reminder(content, messages_array:)
        message_index = messages_array.size - 1
        return if message_index < 0

        add_ephemeral_content_for_message(message_index, content)
      end

      # Prepare messages for LLM API call
      #
      # Embeds ephemeral content into messages for this turn only.
      # Does NOT modify the persistent messages array.
      #
      # @param persistent_messages [Array<RubyLLM::Message>] Messages from @messages
      # @return [Array<RubyLLM::Message>] Messages with ephemeral content embedded
      def prepare_for_llm(persistent_messages)
        return persistent_messages.dup if @ephemeral_content.empty?

        # Clone messages and embed ephemeral content
        messages_for_llm = persistent_messages.map.with_index do |msg, index|
          ephemeral_for_this_msg = @ephemeral_content[index]

          # No ephemeral content for this message - use as-is
          next msg unless ephemeral_for_this_msg&.any?

          # Embed ephemeral content in this message
          original_content = msg.content.is_a?(RubyLLM::Content) ? msg.content.text : msg.content.to_s
          embedded_content = [original_content, *ephemeral_for_this_msg].join("\n\n")

          # Create new message with embedded content
          if msg.content.is_a?(RubyLLM::Content)
            RubyLLM::Message.new(
              role: msg.role,
              content: RubyLLM::Content.new(embedded_content, msg.content.attachments),
              tool_call_id: msg.tool_call_id,
            )
          else
            RubyLLM::Message.new(
              role: msg.role,
              content: embedded_content,
              tool_call_id: msg.tool_call_id,
            )
          end
        end

        messages_for_llm
      end

      # Clear all ephemeral content
      #
      # Should be called after LLM response is received.
      #
      # @return [void]
      def clear_ephemeral
        @ephemeral_content.clear
      end

      # Check if there is pending ephemeral content
      #
      # @return [Boolean] True if ephemeral content exists
      def has_ephemeral?
        @ephemeral_content.any?
      end

      # Get count of messages with ephemeral content
      #
      # @return [Integer] Number of messages with ephemeral content attached
      def ephemeral_count
        @ephemeral_content.size
      end

      # Extract all <system-reminder> blocks from content
      #
      # @param content [String] Content to extract from
      # @return [Array<String>] Array of system reminder blocks
      def extract_system_reminders(content)
        return [] if content.nil? || content.empty?

        content.scan(SYSTEM_REMINDER_REGEX)
      end

      # Strip all <system-reminder> blocks from content
      #
      # Returns clean content without system reminders.
      #
      # @param content [String] Content to strip from
      # @return [String] Clean content
      def strip_system_reminders(content)
        return content if content.nil? || content.empty?

        content.gsub(SYSTEM_REMINDER_REGEX, "").strip
      end

      # Check if content contains system reminders
      #
      # @param content [String] Content to check
      # @return [Boolean] True if reminders found
      def has_system_reminders?(content)
        return false if content.nil? || content.empty?

        SYSTEM_REMINDER_REGEX.match?(content)
      end

      # ============================================================================
      # FUTURE: Context Optimization Methods (Hooks for Later Implementation)
      # ============================================================================

      # Future: Summarize old messages to save context window space
      #
      # @param messages [Array<RubyLLM::Message>] Messages to potentially summarize
      # @param before_index [Integer] Summarize messages before this index
      # @param strategy [Symbol] Summarization strategy (:llm, :truncate, :remove)
      # @return [Array<RubyLLM::Message>] Optimized message array
      def summarize_old_messages(messages, before_index:, strategy: :truncate)
        # TODO: Implement when needed
        messages
      end

      # Future: Truncate messages to fit within context window
      #
      # @param messages [Array<RubyLLM::Message>] Messages to fit
      # @param max_tokens [Integer] Maximum token budget
      # @param keep_recent [Integer] Number of recent messages to always keep
      # @return [Array<RubyLLM::Message>] Truncated messages
      def truncate_to_fit(messages, max_tokens:, keep_recent: 10)
        # TODO: Implement when needed
        messages
      end

      # Compress verbose tool results for older messages
      #
      # Uses progressive compression: older messages are compressed more aggressively.
      # Preserves user/assistant messages at full detail (conversational context).
      #
      # @param messages [Array<RubyLLM::Message>] Messages to compress
      # @param keep_recent [Integer] Number of recent messages to keep at full detail
      # @return [Array<RubyLLM::Message>] Compressed messages
      def compress_tool_results(messages, keep_recent: 10)
        messages.map.with_index do |msg, i|
          # Keep recent messages at full detail
          next msg if i >= messages.size - keep_recent

          # Keep user/assistant messages (conversational flow is important)
          next msg if [:user, :assistant].include?(msg.role)

          # Compress old tool results
          if msg.role == :tool
            compress_tool_message(msg, age: messages.size - i)
          else
            msg
          end
        end
      end

      # Compress a single tool message based on age
      #
      # Progressive compression: older messages get compressed more.
      # For re-runnable tools (Read, Grep, Glob, etc.), adds instruction to re-run if needed.
      #
      # @param msg [RubyLLM::Message] Tool message to compress
      # @param age [Integer] How many messages ago (higher = older)
      # @return [RubyLLM::Message] Compressed message
      def compress_tool_message(msg, age:)
        content = msg.content.to_s

        # Progressive compression based on age
        max_length = case age
        when 0..10   then return msg           # Recent: keep full detail
        when 11..20  then 1000                 # Medium age: light compression
        when 21..40  then 500                  # Old: moderate compression
        when 41..60  then 200                  # Very old: heavy compression
        else              100                  # Ancient: minimal summary
        end

        return msg if content.length <= max_length

        # Compress while preserving structure
        compressed = content.slice(0, max_length)
        truncated_chars = content.length - max_length
        compressed += "\n...[#{truncated_chars} chars truncated for context management]"

        # Detect if this is a re-runnable tool and add helpful instruction
        tool_name = detect_tool_name(content)
        if rerunnable_tool?(tool_name)
          compressed += "\n\n💡 If you need the full output, re-run the #{tool_name} tool with the same parameters."
        end

        RubyLLM::Message.new(
          role: :tool,
          content: compressed,
          tool_call_id: msg.tool_call_id,
        )
      end

      # Detect tool name from content
      #
      # @param content [String] Tool result content
      # @return [String, nil] Tool name or nil
      def detect_tool_name(content)
        # Many tool results have patterns we can detect
        case content
        when /you should consider whether it looks malicious/ # Read tool system reminder
          "Read"
        when /Related memories that may provide additional context:/ # MemoryRead related memories reminder
          "MemoryRead"
        when /^Memory entries matching/ # MemoryGlob
          "MemoryGlob"
        when /^Found \d+ files? matching/ # Glob
          "Glob"
        when /matches in \d+ files?|No matches found/ # Grep, MemoryGrep
          content.include?("memory://") ? "MemoryGrep" : "Grep"
        when %r{^Stored at memory://} # MemoryWrite (not re-runnable but identifiable)
          "MemoryWrite"
        when %r{^Deleted memory://} # MemoryDelete
          "MemoryDelete"
        end
      end

      # Check if a tool is re-runnable (idempotent, can get same data again)
      #
      # @param tool_name [String, nil] Tool name
      # @return [Boolean] True if tool can be re-run safely
      def rerunnable_tool?(tool_name)
        return false if tool_name.nil?

        # These tools are idempotent - re-running gives same/current data
        ["Read", "MemoryRead", "Grep", "MemoryGrep", "Glob", "MemoryGlob"].include?(tool_name)
      end

      # Automatically compress messages when context threshold is hit
      #
      # This is called automatically when context usage crosses 60% threshold.
      # Returns compressed messages array for immediate use.
      #
      # @param messages [Array<RubyLLM::Message>] Current message array
      # @param keep_recent [Integer] Number of recent messages to keep full
      # @return [Array<RubyLLM::Message>] Compressed messages
      def auto_compress_on_threshold(messages, keep_recent: 10)
        return messages if @compression_applied

        # Mark as applied to avoid compressing multiple times
        @compression_applied = true

        compress_tool_results(messages, keep_recent: keep_recent)
      end

      # Reset compression flag (when conversation is reset)
      #
      # @return [void]
      def reset_compression
        @compression_applied = false
      end

      # Future: Detect if context is becoming bloated
      #
      # @param messages [Array<RubyLLM::Message>] Messages to analyze
      # @param threshold [Float] Bloat threshold (0.0-1.0)
      # @return [Hash] Bloat analysis with recommendations
      def analyze_context_bloat(messages, threshold: 0.7)
        # TODO: Implement when needed
        { bloated: false, recommendations: [] }
      end
    end
  end
end
