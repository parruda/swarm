# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # Message serialization and deserialization for snapshots
      #
      # Extracted from Chat to reduce class size and centralize persistence logic.
      module Serialization
        # Create snapshot of current conversation state
        #
        # @return [Hash] Serialized conversation data
        def conversation_snapshot
          {
            messages: @llm_chat.messages.map { |msg| serialize_message(msg) },
            model_id: model_id,
            provider: model_provider,
            timestamp: Time.now.utc.iso8601,
          }
        end

        # Restore conversation from snapshot
        #
        # @param snapshot [Hash] Serialized conversation data
        # @return [self]
        def restore_conversation(snapshot)
          raise ArgumentError, "Invalid snapshot: missing messages" unless snapshot[:messages]

          @llm_chat.messages.clear
          snapshot[:messages].each do |msg_data|
            @llm_chat.messages << deserialize_message(msg_data)
          end

          self
        end

        private

        # Serialize a RubyLLM::Message to a plain hash
        #
        # @param message [RubyLLM::Message] Message to serialize
        # @return [Hash] Serialized message data
        def serialize_message(message)
          data = message.to_h

          # Convert tool_calls to plain hashes (they're ToolCall objects)
          if data[:tool_calls]
            data[:tool_calls] = data[:tool_calls].transform_values(&:to_h)
          end

          # Handle Content objects
          if data[:content].respond_to?(:to_h)
            data[:content] = data[:content].to_h
          end

          data
        end

        # Deserialize a hash back to a RubyLLM::Message
        #
        # @param data [Hash] Serialized message data
        # @return [RubyLLM::Message] Reconstructed message
        def deserialize_message(data)
          data = data.transform_keys(&:to_sym)

          # Convert tool_calls back to ToolCall objects
          if data[:tool_calls]
            data[:tool_calls] = data[:tool_calls].transform_values do |tc_data|
              tc_data = tc_data.transform_keys(&:to_sym)
              RubyLLM::ToolCall.new(
                id: tc_data[:id],
                name: tc_data[:name],
                arguments: tc_data[:arguments] || {},
              )
            end
          end

          RubyLLM::Message.new(**data)
        end
      end
    end
  end
end
