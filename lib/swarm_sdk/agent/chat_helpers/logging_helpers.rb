# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # Helper methods for logging and serialization of tool calls and results
      #
      # Responsibilities:
      # - Format tool calls for logging
      # - Serialize tool results (handling different types)
      # - Calculate LLM costs based on token usage
      #
      # These are stateless utility methods that operate on data structures.
      module LoggingHelpers
        # Format tool calls for logging
        #
        # @param tool_calls_hash [Hash] Tool calls from message
        # @return [Array<Hash>, nil] Formatted tool calls
        def format_tool_calls(tool_calls_hash)
          return unless tool_calls_hash

          tool_calls_hash.map do |_id, tc|
            {
              id: tc.id,
              name: tc.name,
              arguments: tc.arguments,
            }
          end
        end

        # Serialize a tool result for logging
        #
        # Handles multiple result types:
        # - String: pass through
        # - Hash/Array: pass through
        # - RubyLLM::Content: extract text and attachment info
        # - Other: convert to string
        #
        # @param result [String, Hash, Array, RubyLLM::Content, Object] Tool result
        # @return [String, Hash, Array] Serialized result
        def serialize_result(result)
          case result
          when String then result
          when Hash, Array then result
          when RubyLLM::Content
            # Format Content objects to show text and attachment info
            parts = []
            parts << result.text if result.text && !result.text.empty?

            if result.attachments.any?
              attachment_info = result.attachments.map do |att|
                "#{att.source} (#{att.mime_type})"
              end.join(", ")
              parts << "[Attachments: #{attachment_info}]"
            end

            parts.join(" ")
          else
            result.to_s
          end
        end

        # Calculate LLM cost for a message
        #
        # Uses RubyLLM's model registry to get pricing information.
        # Returns zero cost if pricing is unavailable.
        #
        # @param message [RubyLLM::Message] Message with token counts
        # @return [Hash] Cost breakdown { input_cost:, output_cost:, total_cost: }
        def calculate_cost(message)
          return zero_cost unless message.input_tokens && message.output_tokens

          # Use SwarmSDK's model registry (not RubyLLM's) for up-to-date pricing
          model_info = SwarmSDK::Models.find(message.model_id)
          return zero_cost unless model_info

          # Extract pricing from SwarmSDK's models.json structure
          pricing = model_info["pricing"] || model_info[:pricing]
          return zero_cost unless pricing

          text_pricing = pricing["text_tokens"] || pricing[:text_tokens]
          return zero_cost unless text_pricing

          standard_pricing = text_pricing["standard"] || text_pricing[:standard]
          return zero_cost unless standard_pricing

          input_price = standard_pricing["input_per_million"] || standard_pricing[:input_per_million]
          output_price = standard_pricing["output_per_million"] || standard_pricing[:output_per_million]

          return zero_cost unless input_price && output_price

          # Calculate costs (prices are per million tokens in USD)
          input_cost = (message.input_tokens / 1_000_000.0) * input_price
          output_cost = (message.output_tokens / 1_000_000.0) * output_price

          {
            input_cost: input_cost,
            output_cost: output_cost,
            total_cost: input_cost + output_cost,
          }
        rescue StandardError => e
          # Model not found in registry or pricing not available
          RubyLLM.logger.debug("Cost calculation failed for #{message.model_id}: #{e.message}")
          zero_cost
        end

        # Zero cost fallback
        #
        # @return [Hash] Zero cost breakdown
        def zero_cost
          { input_cost: 0.0, output_cost: 0.0, total_cost: 0.0 }
        end
      end
    end
  end
end
