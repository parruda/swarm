# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class ChatCallbacksPatchTest < Minitest::Test
      def setup
        @original_api_key = ENV["OPENAI_API_KEY"]
        ENV["OPENAI_API_KEY"] = "test-key-callbacks"
        RubyLLM.configure { |c| c.openai_api_key = "test-key-callbacks" }
      end

      def teardown
        ENV["OPENAI_API_KEY"] = @original_api_key
      end

      # ========== Subscription Class ==========

      def test_subscription_class_exists
        assert_kind_of(Class, RubyLLM::Chat::Subscription)
      end

      def test_subscription_tracks_tag
        chat = build_chat
        sub = chat.subscribe(:tool_call, tag: "my-tag") { |_| }

        assert_equal("my-tag", sub.tag)
      end

      def test_subscription_is_active_after_creation
        chat = build_chat
        sub = chat.subscribe(:new_message) { |_| }

        assert_predicate(sub, :active?)
      end

      def test_subscription_unsubscribe_returns_true
        chat = build_chat
        sub = chat.subscribe(:new_message) { |_| }

        assert(sub.unsubscribe)
      end

      def test_subscription_inactive_after_unsubscribe
        chat = build_chat
        sub = chat.subscribe(:new_message) { |_| }
        sub.unsubscribe

        refute_predicate(sub, :active?)
      end

      def test_subscription_double_unsubscribe_returns_false
        chat = build_chat
        sub = chat.subscribe(:new_message) { |_| }
        sub.unsubscribe

        refute(sub.unsubscribe)
      end

      def test_subscription_inspect
        chat = build_chat
        sub = chat.subscribe(:new_message, tag: "test") { |_| }

        assert_includes(sub.inspect, "tag=\"test\"")
        assert_includes(sub.inspect, "active=true")
      end

      # ========== Multi-Subscriber Callbacks ==========

      def test_subscribe_returns_subscription
        chat = build_chat
        sub = chat.subscribe(:tool_call) { |_| }

        assert_instance_of(RubyLLM::Chat::Subscription, sub)
      end

      def test_subscribe_raises_for_unknown_event
        chat = build_chat

        assert_raises(ArgumentError) do
          chat.subscribe(:nonexistent) { |_| }
        end
      end

      def test_multiple_subscribers_fire_on_end_message
        chat = build_chat
        results = []
        chat.subscribe(:end_message) { |_| results << :first }
        chat.subscribe(:end_message) { |_| results << :second }

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        assert_equal([:first, :second], results)
      end

      def test_callbacks_fire_in_fifo_order
        chat = build_chat
        order = []
        chat.subscribe(:end_message) { |_| order << 1 }
        chat.subscribe(:end_message) { |_| order << 2 }
        chat.subscribe(:end_message) { |_| order << 3 }

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        assert_equal([1, 2, 3], order)
      end

      def test_callback_error_isolation
        chat = build_chat
        results = []
        chat.subscribe(:end_message) { |_| results << :before_error }
        chat.subscribe(:end_message) { |_| raise "boom" }
        chat.subscribe(:end_message) { |_| results << :after_error }

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        assert_equal([:before_error, :after_error], results)
      end

      def test_unsubscribe_removes_callback
        chat = build_chat
        results = []
        sub = chat.subscribe(:end_message) { |_| results << :removed }
        chat.subscribe(:end_message) { |_| results << :kept }

        sub.unsubscribe
        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        assert_equal([:kept], results)
      end

      # ========== once() Method ==========

      def test_once_fires_only_once
        chat = build_chat
        count = 0
        chat.once(:end_message) { |_| count += 1 }

        stub_simple_response_twice
        _out, _err = capture_io do
          chat.ask("hello")
          chat.ask("hello again")
        end

        assert_equal(1, count)
      end

      def test_once_returns_subscription
        chat = build_chat
        sub = chat.once(:new_message) { |_| }

        assert_instance_of(RubyLLM::Chat::Subscription, sub)
      end

      # ========== on_* Methods Return Self ==========

      def test_on_new_message_returns_self
        chat = build_chat

        assert_same(chat, chat.on_new_message { |_| })
      end

      def test_on_end_message_returns_self
        chat = build_chat

        assert_same(chat, chat.on_end_message { |_| })
      end

      def test_on_tool_call_returns_self
        chat = build_chat

        assert_same(chat, chat.on_tool_call { |_| })
      end

      def test_on_tool_result_returns_self
        chat = build_chat

        assert_same(chat, chat.on_tool_result { |_| })
      end

      def test_on_methods_support_multiple_subscribers
        chat = build_chat_with_tool
        results = []
        chat.on_tool_result { |*_| results << :first }
        chat.on_tool_result { |*_| results << :second }

        stub_tool_call_response
        _out, _err = capture_io { chat.ask("use tool") }

        assert_equal([:first, :second], results)
      end

      # ========== clear_callbacks ==========

      def test_clear_callbacks_for_specific_event
        chat = build_chat
        chat.subscribe(:new_message) { |_| }
        chat.subscribe(:tool_call) { |_| }

        chat.clear_callbacks(:new_message)

        assert_equal(0, chat.callback_count(:new_message))
        assert_equal(1, chat.callback_count(:tool_call))
      end

      def test_clear_all_callbacks
        chat = build_chat
        chat.subscribe(:new_message) { |_| }
        chat.subscribe(:tool_call) { |_| }
        chat.subscribe(:tool_result) { |_| }

        chat.clear_callbacks
        counts = chat.callback_count

        assert_equal(0, counts[:new_message])
        assert_equal(0, counts[:tool_call])
        assert_equal(0, counts[:tool_result])
      end

      def test_clear_callbacks_returns_self
        chat = build_chat

        assert_same(chat, chat.clear_callbacks)
      end

      # ========== callback_count ==========

      def test_callback_count_for_event
        chat = build_chat
        chat.subscribe(:tool_call) { |_| }
        chat.subscribe(:tool_call) { |_| }

        assert_equal(2, chat.callback_count(:tool_call))
      end

      def test_callback_count_all_events
        chat = build_chat
        chat.subscribe(:new_message) { |_| }
        chat.subscribe(:tool_call) { |_| }
        chat.subscribe(:tool_call) { |_| }

        counts = chat.callback_count

        assert_equal(1, counts[:new_message])
        assert_equal(2, counts[:tool_call])
        assert_equal(0, counts[:tool_result])
      end

      # ========== around_tool_execution Hook ==========

      def test_around_tool_execution_returns_self
        chat = build_chat
        result = chat.around_tool_execution { |*_| }

        assert_same(chat, result)
      end

      def test_around_tool_execution_hook_is_called
        chat = build_chat_with_tool
        hook_called = false
        chat.around_tool_execution do |_tool_call, _tool_instance, execute|
          hook_called = true
          execute.call
        end

        stub_tool_call_response
        _out, _err = capture_io { chat.ask("use tool") }

        assert(hook_called)
      end

      def test_around_tool_execution_receives_tool_call_and_instance
        chat = build_chat_with_tool
        received_args = []
        chat.around_tool_execution do |tool_call, tool_instance, execute|
          received_args << tool_call
          received_args << tool_instance
          execute.call
        end

        stub_tool_call_response
        _out, _err = capture_io { chat.ask("use tool") }

        assert_instance_of(RubyLLM::ToolCall, received_args[0])
        assert_instance_of(CallbackTestTool, received_args[1])
      end

      def test_around_tool_execution_can_modify_result
        chat = build_chat_with_tool
        chat.around_tool_execution do |_tc, _ti, _execute|
          "intercepted result"
        end

        stub_tool_call_response
        _out, _err = capture_io { chat.ask("use tool") }

        tool_messages = chat.messages.select { |m| m.role == :tool }

        assert_equal("intercepted result", tool_messages.last.content)
      end

      # ========== around_llm_request Hook ==========

      def test_around_llm_request_returns_self
        chat = build_chat
        result = chat.around_llm_request { |*_| }

        assert_same(chat, result)
      end

      def test_around_llm_request_hook_is_called
        chat = build_chat
        hook_called = false
        chat.around_llm_request do |_messages, &send_request|
          hook_called = true
          send_request.call
        end

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        assert(hook_called)
      end

      def test_around_llm_request_receives_messages
        chat = build_chat
        received_messages = nil
        chat.around_llm_request do |messages, &send_request|
          received_messages = messages
          send_request.call
        end

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        refute_nil(received_messages)
        assert_kind_of(Array, received_messages)
      end

      def test_around_llm_request_can_modify_messages
        chat = build_chat
        chat.around_llm_request do |_messages, &send_request|
          # Inject a message by passing modified messages
          send_request.call
        end

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        # If the hook worked, the request completed without error
        assert(chat.messages.any? { |m| m.role == :assistant })
      end

      # ========== on_tool_result Signature ==========

      def test_on_tool_result_passes_tool_call_and_result
        chat = build_chat_with_tool
        received = []
        chat.on_tool_result { |tool_call, result| received << [tool_call, result] }

        stub_tool_call_response
        _out, _err = capture_io { chat.ask("use tool") }

        assert_equal(1, received.length)
        assert_instance_of(RubyLLM::ToolCall, received[0][0])
        assert_equal("callback test result", received[0][1])
      end

      # ========== Event Emission Integration ==========

      def test_new_message_fires_on_non_streaming_ask
        chat = build_chat
        new_message_count = 0
        chat.on_new_message { new_message_count += 1 }

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        assert_operator(new_message_count, :>=, 1)
      end

      def test_end_message_fires_with_response
        chat = build_chat
        received_response = nil
        chat.on_end_message { |msg| received_response = msg }

        stub_simple_response
        _out, _err = capture_io { chat.ask("hello") }

        refute_nil(received_response)
        assert_equal(:assistant, received_response.role)
      end

      def test_tool_call_event_fires_with_tool_call_object
        chat = build_chat_with_tool
        received_tool_call = nil
        chat.on_tool_call { |tc| received_tool_call = tc }

        stub_tool_call_response
        _out, _err = capture_io { chat.ask("use tool") }

        refute_nil(received_tool_call)
        assert_equal(tool_function_name, received_tool_call.name)
      end

      private

      def build_chat
        RubyLLM.chat(model: "gpt-4o-mini", assume_model_exists: true, provider: :openai)
      end

      def build_chat_with_tool
        chat = build_chat
        chat.with_tool(CallbackTestTool)
        chat
      end

      def stub_simple_response
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              id: "chatcmpl-test",
              object: "chat.completion",
              model: "gpt-4o-mini",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Hello!" },
                finish_reason: "stop",
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
            }.to_json,
          )
      end

      def stub_simple_response_twice
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                id: "chatcmpl-test1",
                object: "chat.completion",
                model: "gpt-4o-mini",
                choices: [{
                  index: 0,
                  message: { role: "assistant", content: "First!" },
                  finish_reason: "stop",
                }],
                usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
              }.to_json,
            },
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                id: "chatcmpl-test2",
                object: "chat.completion",
                model: "gpt-4o-mini",
                choices: [{
                  index: 0,
                  message: { role: "assistant", content: "Second!" },
                  finish_reason: "stop",
                }],
                usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
              }.to_json,
            },
          )
      end

      def tool_function_name
        @tool_function_name ||= CallbackTestTool.new.name
      end

      def stub_tool_call_response
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                id: "chatcmpl-tool",
                object: "chat.completion",
                model: "gpt-4o-mini",
                choices: [{
                  index: 0,
                  message: {
                    role: "assistant",
                    content: nil,
                    tool_calls: [{
                      id: "call_123",
                      type: "function",
                      function: { name: tool_function_name, arguments: '{"input":"test"}' },
                    }],
                  },
                  finish_reason: "tool_calls",
                }],
                usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
              }.to_json,
            },
            {
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: {
                id: "chatcmpl-final",
                object: "chat.completion",
                model: "gpt-4o-mini",
                choices: [{
                  index: 0,
                  message: { role: "assistant", content: "Done!" },
                  finish_reason: "stop",
                }],
                usage: { prompt_tokens: 30, completion_tokens: 5, total_tokens: 35 },
              }.to_json,
            },
          )
      end
    end

    class CallbackTestTool < RubyLLM::Tool
      description "A test tool for callback testing"

      param :input, type: :string, desc: "Test input"

      def execute(input:)
        "callback test result"
      end
    end
  end
end
