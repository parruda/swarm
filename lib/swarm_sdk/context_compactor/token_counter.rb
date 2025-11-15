# frozen_string_literal: true

module SwarmSDK
  class ContextCompactor
    # TokenCounter provides token estimation for messages
    #
    # This uses a simple heuristic approach:
    # - ~4 characters per token for English prose
    # - ~3.5 characters per token for code
    #
    # For production use with OpenAI models, consider using the tiktoken gem
    # for accurate token counting. For Claude models, use Claude's token API.
    #
    # ## Usage
    #
    #   tokens = TokenCounter.estimate_message(message)
    #   total_tokens = TokenCounter.estimate_messages(messages)
    #
    class TokenCounter
      # Backward compatibility aliases - use Defaults module for new code
      CHARS_PER_TOKEN_PROSE = Defaults::TokenEstimation::CHARS_PER_TOKEN_PROSE
      CHARS_PER_TOKEN_CODE = Defaults::TokenEstimation::CHARS_PER_TOKEN_CODE

      class << self
        # Estimate tokens for a single message
        #
        # @param message [RubyLLM::Message] Message to estimate
        # @return [Integer] Estimated token count
        def estimate_message(message)
          case message.role
          when :user, :assistant
            estimate_content(message.content)
          when :system
            estimate_content(message.content)
          when :tool
            # Tool results typically have overhead
            base_overhead = 50
            content_tokens = estimate_content(message.content)
            base_overhead + content_tokens
          else
            # Unknown message type
            begin
              estimate_content(message.content)
            rescue
              0
            end
          end
        end

        # Estimate tokens for multiple messages
        #
        # @param messages [Array<RubyLLM::Message>] Messages to estimate
        # @return [Integer] Total estimated token count
        def estimate_messages(messages)
          messages.sum { |msg| estimate_message(msg) }
        end

        # Estimate tokens for content string
        #
        # Uses heuristic to detect code vs prose and adjust accordingly.
        #
        # @param content [String, RubyLLM::Content, nil] Content to estimate
        # @return [Integer] Estimated token count
        def estimate_content(content)
          return 0 if content.nil?

          # Handle RubyLLM::Content objects
          text = if content.respond_to?(:to_s)
            content.to_s
          else
            content
          end

          return 0 if text.empty?

          # Detect if content is mostly code
          code_ratio = detect_code_ratio(text)

          # Choose characters per token based on content type
          chars_per_token = if code_ratio > 0.1
            CHARS_PER_TOKEN_CODE # Code
          else
            CHARS_PER_TOKEN_PROSE # Prose
          end

          (text.length / chars_per_token).ceil
        end

        private

        # Detect ratio of code characters to total characters
        #
        # @param text [String] Text to analyze
        # @return [Float] Ratio of code indicators (0.0 to 1.0)
        def detect_code_ratio(text)
          # Count code indicator characters
          code_chars = text.scan(/[{}()\[\];]/).length

          return 0.0 if text.empty?

          code_chars.to_f / text.length
        end
      end
    end
  end
end
