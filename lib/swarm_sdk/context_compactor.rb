# frozen_string_literal: true

module SwarmSDK
  # ContextCompactor implements intelligent conversation history compression
  #
  # The Hybrid Production Strategy combines three compression techniques:
  # 1. Tool result pruning - Aggressively truncate tool outputs (80% of tokens!)
  # 2. Checkpoint creation - LLM-generated summaries of conversation chunks
  # 3. Sliding window - Keep recent messages in full detail
  #
  # ## Usage
  #
  #   # From Agent::Chat
  #   metrics = chat.compact_context
  #
  #   # With options
  #   metrics = chat.compact_context(
  #     tool_result_max_length: 500,
  #     checkpoint_threshold: 50,
  #     sliding_window_size: 20,
  #     summarization_model: "claude-3-haiku-20240307"
  #   )
  #
  # ## Metrics
  #
  # Returns a Metrics object with compression stats:
  # - original_message_count / compressed_message_count
  # - original_tokens / compressed_tokens
  # - compression_ratio (e.g., 0.15 = 15% of original)
  # - messages_removed / messages_summarized
  # - time_taken
  #
  class ContextCompactor
    # Default configuration
    DEFAULT_OPTIONS = {
      tool_result_max_length: 500, # Truncate tool results to N chars
      checkpoint_threshold: 50,        # Create checkpoint after N messages
      sliding_window_size: 20,         # Keep last N messages in full
      summarization_model: "claude-3-haiku-20240307", # Fast model for summaries
      preserve_system_messages: true,  # Always keep system messages
      preserve_error_messages: true,   # Always keep error messages
    }.freeze

    # Initialize compactor for a chat instance
    #
    # @param chat [Agent::Chat] The chat instance to compact
    # @param options [Hash] Configuration options (see DEFAULT_OPTIONS)
    def initialize(chat, options = {})
      @chat = chat
      @options = DEFAULT_OPTIONS.merge(options)
      @agent_name = chat.provider.respond_to?(:agent_name) ? chat.provider.agent_name : :unknown
    end

    # Compact the conversation history using hybrid production strategy
    #
    # Returns metrics about the compression operation.
    #
    # @return [ContextCompactor::Metrics] Compression metrics
    def compact
      start_time = Time.now
      original_messages = @chat.messages

      # Emit compression_started event
      LogStream.emit(
        type: "compression_started",
        agent: @agent_name,
        message_count: original_messages.size,
        estimated_tokens: TokenCounter.estimate_messages(original_messages),
      )

      # Step 1: Prune tool results
      pruned = prune_tool_results(original_messages)

      # Step 2: Create checkpoint if needed
      checkpointed = create_checkpoint_if_needed(pruned)

      # Step 3: Apply sliding window
      final_messages = apply_sliding_window(checkpointed)

      # Replace messages in chat
      replace_messages(final_messages)

      # Calculate metrics
      time_taken = Time.now - start_time
      metrics = ContextCompactor::Metrics.new(
        original_messages: original_messages,
        compressed_messages: final_messages,
        time_taken: time_taken,
      )

      # Emit compression_completed event
      LogStream.emit(
        type: "compression_completed",
        agent: @agent_name,
        original_message_count: metrics.original_message_count,
        compressed_message_count: metrics.compressed_message_count,
        original_tokens: metrics.original_tokens,
        compressed_tokens: metrics.compressed_tokens,
        compression_ratio: metrics.compression_ratio,
        messages_removed: metrics.messages_removed,
        messages_summarized: metrics.messages_summarized,
        time_taken: metrics.time_taken.round(3),
      )

      metrics
    end

    private

    # Step 1: Prune tool results to reduce token count
    #
    # Tool results often contain 80%+ of conversation tokens.
    # We truncate them aggressively while preserving errors.
    #
    # @param messages [Array<RubyLLM::Message>] Original messages
    # @return [Array<RubyLLM::Message>] Messages with pruned tool results
    def prune_tool_results(messages)
      max_length = @options[:tool_result_max_length]

      messages.map do |msg|
        # Only prune tool result messages
        next msg unless msg.role == :tool

        # Preserve error messages
        if @options[:preserve_error_messages] && msg.is_error
          next msg
        end

        # Truncate long tool results
        if msg.content.is_a?(String) && msg.content.length > max_length
          truncated_content = msg.content[0...max_length] + "\n\n[... truncated by context compaction ...]"

          # Create new message with truncated content
          # We can't modify messages in place, so we create a new one
          RubyLLM::Message.new(
            role: :tool,
            content: truncated_content,
            tool_call_id: msg.tool_call_id,
          )
        else
          msg
        end
      end
    end

    # Step 2: Create checkpoint if conversation is long enough
    #
    # Checkpoints are LLM-generated summaries that preserve context
    # while drastically reducing token count. We keep recent messages
    # in full detail and checkpoint older conversation.
    #
    # @param messages [Array<RubyLLM::Message>] Pruned messages
    # @return [Array<RubyLLM::Message>] Messages with checkpoint
    def create_checkpoint_if_needed(messages)
      threshold = @options[:checkpoint_threshold]
      window_size = @options[:sliding_window_size]

      # Only checkpoint if we have enough messages
      return messages if messages.size <= threshold

      # Separate system messages, old messages, and recent messages
      system_messages = messages.select { |m| m.role == :system }
      non_system_messages = messages.reject { |m| m.role == :system }

      # Keep recent messages, checkpoint the rest
      recent_messages = non_system_messages.last(window_size)
      old_messages = non_system_messages[0...-window_size]

      # Create checkpoint summary of old messages
      checkpoint_message = create_checkpoint_summary(old_messages)

      # Reconstruct: system messages + checkpoint + recent messages
      system_messages + [checkpoint_message] + recent_messages
    end

    # Step 3: Apply sliding window to keep conversation size bounded
    #
    # After checkpointing, we still apply a sliding window to ensure
    # the conversation doesn't grow unbounded.
    #
    # @param messages [Array<RubyLLM::Message>] Checkpointed messages
    # @return [Array<RubyLLM::Message>] Final messages
    def apply_sliding_window(messages)
      window_size = @options[:sliding_window_size]

      # Separate system messages from others
      system_messages = messages.select { |m| m.role == :system }
      non_system_messages = messages.reject { |m| m.role == :system }

      # Keep only the sliding window of non-system messages
      recent_messages = non_system_messages.last(window_size)

      # Always include system messages
      system_messages + recent_messages
    end

    # Create a checkpoint summary using an LLM
    #
    # Uses a fast model (Haiku) to generate a concise summary of
    # the conversation chunk that preserves critical context.
    #
    # @param messages [Array<RubyLLM::Message>] Messages to summarize
    # @return [RubyLLM::Message] Checkpoint message
    def create_checkpoint_summary(messages)
      # Extract key information for summarization
      user_messages = messages.select { |m| m.role == :user }.map(&:content).compact
      assistant_messages = messages.select { |m| m.role == :assistant }.map(&:content).compact
      tool_calls = messages.select { |m| m.role == :assistant && m.tool_calls&.any? }

      # Build summarization prompt
      prompt = build_summarization_prompt(
        user_messages: user_messages,
        assistant_messages: assistant_messages,
        tool_calls: tool_calls,
        message_count: messages.size,
      )

      # Generate summary using fast model
      summary = generate_summary(prompt)

      # Create checkpoint message
      checkpoint_content = <<~CHECKPOINT
        [CONVERSATION CHECKPOINT - #{Time.now.utc.iso8601}]

        #{summary}

        --- Continuing conversation from this point ---
      CHECKPOINT

      RubyLLM::Message.new(
        role: :system,
        content: checkpoint_content,
      )
    end

    # Build the summarization prompt for the LLM
    #
    # @param user_messages [Array<String>] User message contents
    # @param assistant_messages [Array<String>] Assistant message contents
    # @param tool_calls [Array<RubyLLM::Message>] Messages with tool calls
    # @param message_count [Integer] Total messages being summarized
    # @return [String] Summarization prompt
    def build_summarization_prompt(user_messages:, assistant_messages:, tool_calls:, message_count:)
      # Format tool calls for context
      tools_used = tool_calls.flat_map do |msg|
        msg.tool_calls.map { |_id, tc| tc.name }
      end.uniq

      # Get last few user messages for context
      recent_user_messages = user_messages.last(5).join("\n---\n")

      <<~PROMPT
        You are a conversation summarization specialist. Create a concise summary of this conversation
        that preserves all critical information needed for the assistant to continue working effectively.

        CONVERSATION STATS:
        - Total messages: #{message_count}
        - User messages: #{user_messages.size}
        - Assistant responses: #{assistant_messages.size}
        - Tools used: #{tools_used.join(", ")}

        RECENT USER REQUESTS (last 5):
        #{recent_user_messages}

        INSTRUCTIONS:
        Create a structured summary with these sections:

        ## Summary
        Brief overview of what has been discussed and accomplished (2-3 sentences)

        ## Key Facts Discovered
        - List important facts, findings, or observations
        - Include file paths, variable names, configurations discussed
        - Note any errors or issues encountered

        ## Decisions Made
        - List key decisions or approaches agreed upon
        - Include rationale if relevant

        ## Current State
        - What is the current state of the work?
        - What files or systems have been modified?
        - What is working / what needs work?

        ## Tools & Actions Completed
        - Summarize major tool calls and their outcomes
        - Focus on successful operations and their results

        Be concise but comprehensive. Preserve all information the assistant will need to continue
        the conversation seamlessly. Use bullet points for clarity.
      PROMPT
    end

    # Generate summary using a fast LLM model
    #
    # @param prompt [String] Summarization prompt
    # @return [String] Generated summary
    def generate_summary(prompt)
      # Create a temporary chat for summarization
      summary_chat = RubyLLM::Chat.new(
        model: @options[:summarization_model],
        context: @chat.provider.client.context, # Use same context (API keys, etc.)
      )

      summary_chat.with_instructions("You are a precise conversation summarization assistant.")

      response = summary_chat.ask(prompt)
      response.content
    rescue StandardError => e
      # If summarization fails, create a simple fallback summary
      LogStream.emit_error(e, source: "context_compactor", context: "generate_summary", agent: @agent_name)
      RubyLLM.logger.debug("ContextCompactor: Summarization failed: #{e.message}")

      <<~FALLBACK
        ## Summary
        Previous conversation involved multiple exchanges. Conversation compacted due to context limits.

        ## Note
        Summarization failed - continuing with reduced context. If critical information was lost,
        please ask the user to provide it again.
      FALLBACK
    end

    # Replace messages in the chat
    #
    # Delegates to the Chat's replace_messages method which provides
    # a safe abstraction over the internal message array.
    #
    # @param new_messages [Array<RubyLLM::Message>] New message array
    # @return [void]
    def replace_messages(new_messages)
      @chat.replace_messages(new_messages)
    end
  end
end
