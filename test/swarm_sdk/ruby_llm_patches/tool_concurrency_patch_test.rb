# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class ToolConcurrencyPatchTest < Minitest::Test
      def setup
        @original_api_key = ENV["OPENAI_API_KEY"]
        ENV["OPENAI_API_KEY"] = "test-key-concurrency"
        RubyLLM.configure { |c| c.openai_api_key = "test-key-concurrency" }
      end

      def teardown
        ENV["OPENAI_API_KEY"] = @original_api_key
      end

      # ========== Tool Executor Registry ==========

      def test_tool_executors_registry_exists
        assert_respond_to(RubyLLM, :tool_executors)
        assert_kind_of(Hash, RubyLLM.tool_executors)
      end

      def test_async_executor_registered
        assert(RubyLLM.tool_executors.key?(:async))
      end

      def test_threads_executor_registered
        assert(RubyLLM.tool_executors.key?(:threads))
      end

      def test_register_custom_executor
        RubyLLM.register_tool_executor(:custom_test) { |*_| {} }

        assert(RubyLLM.tool_executors.key?(:custom_test))
      ensure
        RubyLLM.tool_executors.delete(:custom_test)
      end

      def test_get_unknown_executor_raises
        assert_raises(ArgumentError) do
          RubyLLM.get_tool_executor(:nonexistent)
        end
      end

      def test_get_registered_executor
        executor = RubyLLM.get_tool_executor(:async)

        assert_respond_to(executor, :call)
      end

      # ========== Chat Concurrency Options ==========

      def test_chat_accepts_tool_concurrency_option
        chat = RubyLLM.chat(
          model: "gpt-4o-mini",
          assume_model_exists: true,
          provider: :openai,
          tool_concurrency: :async,
        )

        assert_equal(:async, chat.tool_concurrency)
      end

      def test_chat_accepts_max_concurrency_option
        chat = RubyLLM.chat(
          model: "gpt-4o-mini",
          assume_model_exists: true,
          provider: :openai,
          max_concurrency: 5,
        )

        assert_equal(5, chat.max_concurrency)
      end

      def test_chat_defaults_to_no_concurrency
        chat = build_chat

        assert_nil(chat.tool_concurrency)
        assert_nil(chat.max_concurrency)
      end

      def test_with_tool_concurrency_method
        chat = build_chat
        result = chat.with_tool_concurrency(:threads, max: 3)

        assert_same(chat, result)
        assert_equal(:threads, chat.tool_concurrency)
        assert_equal(3, chat.max_concurrency)
      end

      # ========== Threads Executor ==========

      def test_threads_executor_executes_tools
        executor = RubyLLM.get_tool_executor(:threads)
        tool_calls = [
          mock_tool_call("call_1", "tool_a"),
          mock_tool_call("call_2", "tool_b"),
        ]

        results = executor.call(tool_calls, max_concurrency: 2) do |tc|
          "result_#{tc.id}"
        end

        assert_equal("result_call_1", results["call_1"])
        assert_equal("result_call_2", results["call_2"])
      end

      def test_threads_executor_handles_errors
        executor = RubyLLM.get_tool_executor(:threads)
        tool_calls = [mock_tool_call("call_1", "tool_a")]

        results = nil
        _out, _err = capture_io do
          results = executor.call(tool_calls, max_concurrency: nil) do |_tc|
            raise "test error"
          end
        end

        assert_match(/Error:.*test error/, results["call_1"])
      end

      def test_threads_executor_respects_max_concurrency
        executor = RubyLLM.get_tool_executor(:threads)
        tool_calls = (1..5).map { |i| mock_tool_call("call_#{i}", "tool") }
        max_concurrent = 0
        current_concurrent = 0
        mutex = Mutex.new

        executor.call(tool_calls, max_concurrency: 2) do |tc|
          mutex.synchronize { current_concurrent += 1 }
          mutex.synchronize { max_concurrent = [max_concurrent, current_concurrent].max }
          sleep(0.01)
          mutex.synchronize { current_concurrent -= 1 }
          "done_#{tc.id}"
        end

        assert_operator(max_concurrent, :<=, 2)
      end

      # ========== Async Executor ==========

      def test_async_executor_executes_tools
        executor = RubyLLM.get_tool_executor(:async)
        tool_calls = [
          mock_tool_call("call_1", "tool_a"),
          mock_tool_call("call_2", "tool_b"),
        ]

        results = executor.call(tool_calls, max_concurrency: 2) do |tc|
          "async_result_#{tc.id}"
        end

        assert_equal("async_result_call_1", results["call_1"])
        assert_equal("async_result_call_2", results["call_2"])
      end

      def test_async_executor_handles_errors
        executor = RubyLLM.get_tool_executor(:async)
        tool_calls = [mock_tool_call("call_1", "tool_a")]

        results = nil
        _out, _err = capture_io do
          results = executor.call(tool_calls, max_concurrency: nil) do |_tc|
            raise "async error"
          end
        end

        assert_match(/Error:.*async error/, results["call_1"])
      end

      def test_async_executor_respects_max_concurrency
        executor = RubyLLM.get_tool_executor(:async)
        tool_calls = (1..5).map { |i| mock_tool_call("call_#{i}", "tool") }
        max_concurrent = 0
        current_concurrent = 0
        mutex = Mutex.new

        executor.call(tool_calls, max_concurrency: 2) do |tc|
          mutex.synchronize { current_concurrent += 1 }
          mutex.synchronize { max_concurrent = [max_concurrent, current_concurrent].max }
          sleep(0.01)
          mutex.synchronize { current_concurrent -= 1 }
          "done_#{tc.id}"
        end

        assert_operator(max_concurrent, :<=, 2)
      end

      # ========== Concurrent Tool Execution Integration ==========

      def test_concurrent_execution_falls_back_to_sequential
        chat = build_chat
        chat.with_tool(ConcurrencyTestTool)
        # No tool_concurrency set, should use sequential execution
        stub_tool_call_response_multi(2)

        _out, _err = capture_io { chat.ask("call tools") }
        tool_messages = chat.messages.select { |m| m.role == :tool }

        assert_equal(2, tool_messages.length)
      end

      private

      def build_chat
        RubyLLM.chat(model: "gpt-4o-mini", assume_model_exists: true, provider: :openai)
      end

      MockToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

      def mock_tool_call(id, name)
        MockToolCall.new(id: id, name: name, arguments: {})
      end

      def stub_tool_call_response_multi(count)
        tool_calls = count.times.map do |i|
          {
            id: "call_#{i}",
            type: "function",
            function: { name: "concurrency_test_tool", arguments: "{\"input\":\"test_#{i}\"}" },
          }
        end

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
                  message: { role: "assistant", content: nil, tool_calls: tool_calls },
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

    class ConcurrencyTestTool < RubyLLM::Tool
      description "A test tool for concurrency testing"

      param :input, type: :string, desc: "Test input"

      def execute(input:)
        "concurrent_result_#{input}"
      end
    end
  end
end
