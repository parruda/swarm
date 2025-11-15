# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # Token usage tracking and context limit management
      #
      # Extracted from Chat to reduce class size and centralize token metrics.
      module TokenTracking
        # Get context window limit for the current model
        #
        # @return [Integer, nil] Maximum context tokens
        def context_limit
          return @explicit_context_window if @explicit_context_window
          return @real_model_info.context_window if @real_model_info&.context_window

          internal_model.context_window
        rescue StandardError
          nil
        end

        # Calculate cumulative input tokens for the conversation
        #
        # Gets input_tokens from the most recent assistant message, which represents
        # the total context size sent to the model (not sum of all messages).
        #
        # @return [Integer] Total input tokens used
        def cumulative_input_tokens
          internal_messages.reverse.find { |msg| msg.role == :assistant && msg.input_tokens }&.input_tokens || 0
        end

        # Calculate cumulative output tokens across all assistant messages
        #
        # @return [Integer] Total output tokens used
        def cumulative_output_tokens
          internal_messages.select { |msg| msg.role == :assistant }.sum { |msg| msg.output_tokens || 0 }
        end

        # Calculate cumulative cached tokens
        #
        # @return [Integer] Total cached tokens used
        def cumulative_cached_tokens
          internal_messages.select { |msg| msg.role == :assistant }.sum { |msg| msg.cached_tokens || 0 }
        end

        # Calculate cumulative cache creation tokens
        #
        # @return [Integer] Total tokens written to cache
        def cumulative_cache_creation_tokens
          internal_messages.select { |msg| msg.role == :assistant }.sum { |msg| msg.cache_creation_tokens || 0 }
        end

        # Calculate effective input tokens (excluding cache hits)
        #
        # @return [Integer] Actual input tokens charged
        def effective_input_tokens
          cumulative_input_tokens - cumulative_cached_tokens
        end

        # Calculate total tokens used (input + output)
        #
        # @return [Integer] Total tokens used
        def cumulative_total_tokens
          cumulative_input_tokens + cumulative_output_tokens
        end

        # Calculate percentage of context window used
        #
        # @return [Float] Percentage (0.0 to 100.0)
        def context_usage_percentage
          limit = context_limit
          return 0.0 if limit.nil? || limit.zero?

          (cumulative_total_tokens.to_f / limit * 100).round(2)
        end

        # Calculate remaining tokens in context window
        #
        # @return [Integer, nil] Tokens remaining
        def tokens_remaining
          limit = context_limit
          return if limit.nil?

          limit - cumulative_total_tokens
        end

        # Compact the conversation history to reduce token usage
        #
        # @param options [Hash] Compression options
        # @return [ContextCompactor::Metrics] Compression statistics
        def compact_context(**options)
          compactor = ContextCompactor.new(self, options)
          compactor.compact
        end
      end
    end
  end
end
