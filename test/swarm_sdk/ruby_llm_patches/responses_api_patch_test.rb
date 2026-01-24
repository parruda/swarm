# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class ResponsesApiPatchTest < Minitest::Test
      def setup
        @original_api_key = ENV["OPENAI_API_KEY"]
        ENV["OPENAI_API_KEY"] = "test-key-responses"
        RubyLLM.configure { |c| c.openai_api_key = "test-key-responses" }
      end

      def teardown
        ENV["OPENAI_API_KEY"] = @original_api_key
      end

      # ========== Error Classes ==========

      def test_responses_api_error_exists
        assert_kind_of(Class, RubyLLM::ResponsesApiError)
        assert_operator(RubyLLM::ResponsesApiError, :<, RubyLLM::Error)
      end

      def test_response_id_not_found_error_exists
        assert_kind_of(Class, RubyLLM::ResponseIdNotFoundError)
        assert_operator(RubyLLM::ResponseIdNotFoundError, :<, RubyLLM::ResponsesApiError)
      end

      def test_response_failed_error_exists
        assert_kind_of(Class, RubyLLM::ResponseFailedError)
        assert_operator(RubyLLM::ResponseFailedError, :<, RubyLLM::ResponsesApiError)
      end

      def test_response_in_progress_error_exists
        assert_kind_of(Class, RubyLLM::ResponseInProgressError)
        assert_operator(RubyLLM::ResponseInProgressError, :<, RubyLLM::ResponsesApiError)
      end

      def test_response_cancelled_error_exists
        assert_kind_of(Class, RubyLLM::ResponseCancelledError)
        assert_operator(RubyLLM::ResponseCancelledError, :<, RubyLLM::ResponsesApiError)
      end

      def test_response_incomplete_error_exists
        assert_kind_of(Class, RubyLLM::ResponseIncompleteError)
        assert_operator(RubyLLM::ResponseIncompleteError, :<, RubyLLM::ResponsesApiError)
      end

      # ========== ResponsesSession ==========

      def test_session_initializes_with_defaults
        session = RubyLLM::ResponsesSession.new

        assert_nil(session.response_id)
        assert_nil(session.last_activity)
        assert_equal(0, session.failure_count)
        refute_predicate(session, :disabled?)
      end

      def test_session_update_sets_response_id_and_time
        session = RubyLLM::ResponsesSession.new
        session.update("resp_123")

        assert_equal("resp_123", session.response_id)
        refute_nil(session.last_activity)
        assert_equal(0, session.failure_count)
      end

      def test_session_valid_after_update
        session = RubyLLM::ResponsesSession.new
        session.update("resp_123")

        assert_predicate(session, :valid?)
      end

      def test_session_invalid_without_response_id
        session = RubyLLM::ResponsesSession.new

        refute_predicate(session, :valid?)
      end

      def test_session_invalid_when_disabled
        session = RubyLLM::ResponsesSession.new(disabled: true)
        session.update("resp_123")

        refute_predicate(session, :valid?)
      end

      def test_session_reset_clears_all_state
        session = RubyLLM::ResponsesSession.new
        session.update("resp_123")
        session.record_failure!

        session.reset!

        assert_nil(session.response_id)
        assert_nil(session.last_activity)
        assert_equal(0, session.failure_count)
        refute_predicate(session, :disabled?)
      end

      def test_session_record_failure_increments_count
        session = RubyLLM::ResponsesSession.new
        session.update("resp_123")

        session.record_failure!

        assert_equal(1, session.failure_count)
        assert_nil(session.response_id)
      end

      def test_session_disables_after_max_failures
        session = RubyLLM::ResponsesSession.new
        session.update("resp_123")

        RubyLLM::ResponsesSession::MAX_FAILURES.times { session.record_failure! }

        assert_predicate(session, :disabled?)
      end

      def test_session_to_h_serialization
        session = RubyLLM::ResponsesSession.new
        session.update("resp_456")

        hash = session.to_h

        assert_equal("resp_456", hash[:response_id])
        refute_nil(hash[:last_activity])
        assert_equal(0, hash[:failure_count])
        refute(hash[:disabled])
      end

      def test_session_from_h_deserialization
        original = RubyLLM::ResponsesSession.new
        original.update("resp_789")

        restored = RubyLLM::ResponsesSession.from_h(original.to_h)

        assert_equal("resp_789", restored.response_id)
        assert_equal(0, restored.failure_count)
        refute_predicate(restored, :disabled?)
      end

      def test_session_from_h_with_string_keys
        hash = { "response_id" => "resp_abc", "failure_count" => 1, "disabled" => false }

        session = RubyLLM::ResponsesSession.from_h(hash)

        assert_equal("resp_abc", session.response_id)
        assert_equal(1, session.failure_count)
      end

      # ========== OpenAIResponses Provider ==========

      def test_openai_responses_provider_exists
        assert_kind_of(Class, RubyLLM::Providers::OpenAIResponses)
      end

      def test_openai_responses_inherits_from_openai
        assert_operator(RubyLLM::Providers::OpenAIResponses, :<, RubyLLM::Providers::OpenAI)
      end

      def test_openai_responses_completion_url
        config = RubyLLM::Configuration.new
        config.openai_api_key = "test-key"
        provider = RubyLLM::Providers::OpenAIResponses.new(config)

        assert_equal("responses", provider.completion_url)
      end

      def test_openai_responses_default_config
        config = RubyLLM::Configuration.new
        config.openai_api_key = "test-key"
        provider = RubyLLM::Providers::OpenAIResponses.new(config)

        refute(provider.responses_config[:stateful])
        assert(provider.responses_config[:store])
        assert_equal(:disabled, provider.responses_config[:truncation])
      end

      def test_openai_responses_custom_config
        config = RubyLLM::Configuration.new
        config.openai_api_key = "test-key"
        custom_config = { stateful: true, store: false }
        provider = RubyLLM::Providers::OpenAIResponses.new(config, nil, custom_config)

        assert(provider.responses_config[:stateful])
        refute(provider.responses_config[:store])
      end

      def test_openai_responses_creates_session_if_nil
        config = RubyLLM::Configuration.new
        config.openai_api_key = "test-key"
        provider = RubyLLM::Providers::OpenAIResponses.new(config, nil)

        assert_instance_of(RubyLLM::ResponsesSession, provider.responses_session)
      end

      def test_openai_responses_uses_provided_session
        config = RubyLLM::Configuration.new
        config.openai_api_key = "test-key"
        session = RubyLLM::ResponsesSession.new
        session.update("resp_existing")
        provider = RubyLLM::Providers::OpenAIResponses.new(config, session)

        assert_same(session, provider.responses_session)
        assert_equal("resp_existing", provider.responses_session.response_id)
      end

      # ========== Streaming Chunk Building ==========

      def test_build_chunk_handles_output_text_delta
        provider = build_provider
        data = { "type" => "response.output_text.delta", "delta" => "Hello world" }

        chunk = provider.build_chunk(data)

        assert_equal("Hello world", chunk.content)
        assert_equal(:assistant, chunk.role)
      end

      def test_build_chunk_handles_empty_delta
        provider = build_provider
        data = { "type" => "response.output_text.delta", "delta" => "" }

        chunk = provider.build_chunk(data)

        assert_equal("", chunk.content)
      end

      def test_build_chunk_handles_nil_delta
        provider = build_provider
        data = { "type" => "response.output_text.delta" }

        chunk = provider.build_chunk(data)

        assert_equal("", chunk.content)
      end

      def test_build_chunk_handles_response_completed
        provider = build_provider
        data = {
          "type" => "response.completed",
          "response" => {
            "model" => "gpt-4o",
            "usage" => { "input_tokens" => 10, "output_tokens" => 20 },
          },
        }

        chunk = provider.build_chunk(data)

        assert_nil(chunk.content)
        assert_equal("gpt-4o", chunk.model_id)
        assert_equal(10, chunk.input_tokens)
        assert_equal(20, chunk.output_tokens)
      end

      def test_build_chunk_handles_unrecognized_response_events
        provider = build_provider
        data = { "type" => "response.created" }

        chunk = provider.build_chunk(data)

        assert_nil(chunk.content)
        assert_equal(:assistant, chunk.role)
      end

      def test_build_chunk_handles_function_call_output_item_done
        provider = build_provider
        data = {
          "type" => "response.output_item.done",
          "item" => {
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "my_tool",
            "arguments" => '{"key":"value"}',
          },
        }

        chunk = provider.build_chunk(data)

        assert_nil(chunk.content)
        refute_nil(chunk.tool_calls)
        assert_equal("my_tool", chunk.tool_calls["call_abc"].name)
      end

      # ========== Chat Methods ==========

      def test_with_responses_api_returns_self
        chat = build_chat

        assert_same(chat, chat.with_responses_api)
      end

      def test_with_responses_api_enables_flag
        chat = build_chat
        chat.with_responses_api

        assert_predicate(chat, :responses_api_enabled?)
      end

      def test_responses_api_disabled_by_default
        chat = build_chat

        refute_predicate(chat, :responses_api_enabled?)
      end

      def test_with_responses_api_creates_session
        chat = build_chat
        chat.with_responses_api

        assert_instance_of(RubyLLM::ResponsesSession, chat.responses_session)
      end

      def test_with_responses_api_accepts_options
        chat = build_chat
        chat.with_responses_api(stateful: true, store: false, truncation: :auto)

        assert_predicate(chat, :responses_api_enabled?)
      end

      def test_restore_responses_session
        chat = build_chat
        chat.with_responses_api(stateful: true)

        session_hash = { response_id: "resp_restored", failure_count: 0, disabled: false }
        chat.restore_responses_session(session_hash)

        assert_equal("resp_restored", chat.responses_session.response_id)
      end

      def test_restore_responses_session_returns_self
        chat = build_chat
        chat.with_responses_api

        result = chat.restore_responses_session({ response_id: nil })

        assert_same(chat, result)
      end

      private

      def build_provider
        config = RubyLLM::Configuration.new
        config.openai_api_key = "test-key"
        RubyLLM::Providers::OpenAIResponses.new(config)
      end

      def build_chat
        RubyLLM.chat(model: "gpt-4o-mini", assume_model_exists: true, provider: :openai)
      end
    end
  end
end
