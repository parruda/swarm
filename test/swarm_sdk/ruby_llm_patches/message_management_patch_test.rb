# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class MessageManagementPatchTest < Minitest::Test
      def setup
        @original_api_key = ENV["OPENAI_API_KEY"]
        ENV["OPENAI_API_KEY"] = "test-key-messages"
        RubyLLM.configure { |c| c.openai_api_key = "test-key-messages" }
      end

      def teardown
        ENV["OPENAI_API_KEY"] = @original_api_key
      end

      # ========== reset_messages! with preserve_system_prompt ==========

      def test_reset_messages_preserves_system_prompt_by_default
        chat = build_chat
        chat.with_instructions("You are helpful")
        chat.add_message(role: :user, content: "hello")
        chat.add_message(role: :assistant, content: "hi")

        chat.reset_messages!

        assert_equal(1, chat.messages.length)
        assert_equal(:system, chat.messages.first.role)
        assert_equal("You are helpful", chat.messages.first.content)
      end

      def test_reset_messages_with_preserve_true
        chat = build_chat
        chat.with_instructions("System prompt")
        chat.add_message(role: :user, content: "test")

        chat.reset_messages!(preserve_system_prompt: true)

        assert_equal(1, chat.messages.length)
        assert_equal(:system, chat.messages.first.role)
      end

      def test_reset_messages_with_preserve_false_clears_all
        chat = build_chat
        chat.with_instructions("System prompt")
        chat.add_message(role: :user, content: "test")

        chat.reset_messages!(preserve_system_prompt: false)

        assert_empty(chat.messages)
      end

      def test_reset_messages_returns_self
        chat = build_chat
        chat.add_message(role: :user, content: "test")

        assert_same(chat, chat.reset_messages!)
      end

      def test_reset_messages_preserves_multiple_system_messages
        chat = build_chat
        chat.with_instructions("First instruction")
        chat.with_instructions("Second instruction")
        chat.add_message(role: :user, content: "test")
        chat.add_message(role: :assistant, content: "response")

        chat.reset_messages!

        system_messages = chat.messages.select { |m| m.role == :system }

        assert_equal(2, system_messages.length)
      end

      def test_reset_messages_without_system_messages_clears_all
        chat = build_chat
        chat.add_message(role: :user, content: "test")
        chat.add_message(role: :assistant, content: "response")

        chat.reset_messages!

        assert_empty(chat.messages)
      end

      private

      def build_chat
        RubyLLM.chat(model: "gpt-4o-mini", assume_model_exists: true, provider: :openai)
      end
    end
  end
end
