# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Agent
    class LLMInstrumentationMiddlewareTest < Minitest::Test
      def setup
        @request_events = []
        @response_events = []

        @on_request = ->(data) { @request_events << data }
        @on_response = ->(data) { @response_events << data }

        # Create a simple Faraday app that returns a mock response
        @app = lambda do |_env|
          Faraday::Response.new(
            status: 200,
            response_headers: {},
            body: { model: "gpt-4", usage: { prompt_tokens: 10, completion_tokens: 5 } }.to_json,
          )
        end

        @middleware = LLMInstrumentationMiddleware.new(
          @app,
          on_request: @on_request,
          on_response: @on_response,
          provider_name: "openai",
        )
      end

      def test_call_emits_request_and_response_events
        env = create_faraday_env

        @middleware.call(env)

        assert_equal(1, @request_events.size)
        assert_equal(1, @response_events.size)
      end

      def test_request_event_includes_provider
        env = create_faraday_env

        @middleware.call(env)

        request_data = @request_events.first

        assert_equal("openai", request_data[:provider])
      end

      def test_request_event_includes_timestamp
        env = create_faraday_env

        @middleware.call(env)

        request_data = @request_events.first

        assert(request_data[:timestamp])
        assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, request_data[:timestamp])
      end

      def test_request_event_includes_parsed_body
        env = create_faraday_env(body: { model: "gpt-4", messages: [] }.to_json)

        @middleware.call(env)

        request_data = @request_events.first

        assert_instance_of(Hash, request_data[:body])
        assert_equal("gpt-4", request_data[:body]["model"])
      end

      def test_response_event_includes_duration
        env = create_faraday_env

        @middleware.call(env)

        response_data = @response_events.first

        assert(response_data[:duration_seconds])
        assert_instance_of(Float, response_data[:duration_seconds])
      end

      def test_response_event_extracts_usage_stats
        app = lambda do |_env|
          Faraday::Response.new(
            status: 200,
            body: { usage: { prompt_tokens: 100, completion_tokens: 50 } }.to_json,
          )
        end

        middleware = LLMInstrumentationMiddleware.new(
          app,
          on_request: @on_request,
          on_response: @on_response,
          provider_name: "openai",
        )

        env = create_faraday_env
        middleware.call(env)

        response_data = @response_events.first

        assert(response_data[:usage])
        assert_equal(100, response_data[:usage][:input_tokens])
        assert_equal(50, response_data[:usage][:output_tokens])
      end

      def test_response_event_extracts_model
        app = lambda do |_env|
          Faraday::Response.new(
            status: 200,
            body: { model: "gpt-5-pro", usage: {} }.to_json,
          )
        end

        middleware = LLMInstrumentationMiddleware.new(
          app,
          on_request: @on_request,
          on_response: @on_response,
          provider_name: "openai",
        )

        env = create_faraday_env
        middleware.call(env)

        response_data = @response_events.first

        assert_equal("gpt-5-pro", response_data[:model])
      end

      def test_response_event_extracts_finish_reason_openai_format
        app = lambda do |_env|
          Faraday::Response.new(
            status: 200,
            body: { choices: [{ finish_reason: "stop" }] }.to_json,
          )
        end

        middleware = LLMInstrumentationMiddleware.new(
          app,
          on_request: @on_request,
          on_response: @on_response,
          provider_name: "openai",
        )

        env = create_faraday_env
        middleware.call(env)

        response_data = @response_events.first

        assert_equal("stop", response_data[:finish_reason])
      end

      def test_response_event_extracts_finish_reason_anthropic_format
        app = lambda do |_env|
          Faraday::Response.new(
            status: 200,
            body: { stop_reason: "end_turn" }.to_json,
          )
        end

        middleware = LLMInstrumentationMiddleware.new(
          app,
          on_request: @on_request,
          on_response: @on_response,
          provider_name: "anthropic",
        )

        env = create_faraday_env
        middleware.call(env)

        response_data = @response_events.first

        assert_equal("end_turn", response_data[:finish_reason])
      end

      def test_parse_body_with_nil
        middleware = create_middleware

        result = middleware.instance_eval { parse_body(nil) }

        assert_nil(result)
      end

      def test_parse_body_with_empty_string
        middleware = create_middleware

        result = middleware.instance_eval { parse_body("") }

        assert_nil(result)
      end

      def test_parse_body_with_hash
        middleware = create_middleware
        body = { test: "value" }

        result = middleware.instance_eval { parse_body(body) }

        assert_equal(body, result)
      end

      def test_parse_body_with_json_string
        middleware = create_middleware
        body = '{"test":"value"}'

        result = middleware.instance_eval { parse_body(body) }

        assert_instance_of(Hash, result)
        assert_equal("value", result["test"])
      end

      def test_parse_body_with_non_json_string
        middleware = create_middleware
        body = "Not JSON content" * 100

        result = middleware.instance_eval { parse_body(body) }

        # Should return full string for non-JSON content (SSE, etc.)
        assert_instance_of(String, result)
        assert_equal(body.length, result.length)
      end

      def test_parse_body_with_invalid_data
        middleware = create_middleware

        # Test with object that raises error during parsing
        result = middleware.instance_eval { parse_body(Object.new) }

        assert_nil(result)
      end

      def test_extract_usage_with_openai_format
        middleware = create_middleware
        parsed = { "usage" => { "prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150 } }

        usage = middleware.instance_eval { extract_usage(parsed) }

        assert_equal(100, usage[:input_tokens])
        assert_equal(50, usage[:output_tokens])
        assert_equal(150, usage[:total_tokens])
      end

      def test_extract_usage_with_anthropic_format
        middleware = create_middleware
        parsed = { "usage" => { "input_tokens" => 120, "output_tokens" => 60 } }

        usage = middleware.instance_eval { extract_usage(parsed) }

        assert_equal(120, usage[:input_tokens])
        assert_equal(60, usage[:output_tokens])
      end

      def test_extract_usage_with_missing_usage
        middleware = create_middleware
        parsed = { "model" => "gpt-4" }

        usage = middleware.instance_eval { extract_usage(parsed) }

        assert_nil(usage)
      end

      def test_extract_finish_reason_with_anthropic_format
        middleware = create_middleware
        parsed = { "stop_reason" => "end_turn" }

        reason = middleware.instance_eval { extract_finish_reason(parsed) }

        assert_equal("end_turn", reason)
      end

      def test_extract_finish_reason_with_openai_format
        middleware = create_middleware
        parsed = { "choices" => [{ "finish_reason" => "tool_calls" }] }

        reason = middleware.instance_eval { extract_finish_reason(parsed) }

        assert_equal("tool_calls", reason)
      end

      def test_extract_finish_reason_with_empty_choices
        middleware = create_middleware
        parsed = { "choices" => [] }

        reason = middleware.instance_eval { extract_finish_reason(parsed) }

        assert_nil(reason)
      end

      def test_extract_finish_reason_with_nil_choices
        middleware = create_middleware
        parsed = { "model" => "gpt-4" }

        reason = middleware.instance_eval { extract_finish_reason(parsed) }

        assert_nil(reason)
      end

      def test_middleware_doesnt_break_on_request_callback_error
        bad_on_request = ->(_data) { raise "Intentional error" }

        middleware = LLMInstrumentationMiddleware.new(
          @app,
          on_request: bad_on_request,
          on_response: @on_response,
          provider_name: "openai",
        )

        env = create_faraday_env

        # Should not raise despite callback error
        result = middleware.call(env)

        assert(result)
      end

      def test_middleware_doesnt_break_on_response_callback_error
        bad_on_response = ->(_data) { raise "Intentional error" }

        middleware = LLMInstrumentationMiddleware.new(
          @app,
          on_request: @on_request,
          on_response: bad_on_response,
          provider_name: "openai",
        )

        env = create_faraday_env

        # Should not raise despite callback error
        result = middleware.call(env)

        assert(result)
      end

      private

      def create_middleware
        LLMInstrumentationMiddleware.new(
          @app,
          on_request: @on_request,
          on_response: @on_response,
          provider_name: "test",
        )
      end

      def create_faraday_env(body: '{"test":"value"}')
        Faraday::Env.new.tap do |env|
          env.url = URI("https://api.test.com/v1/chat/completions")
          env.method = :post
          env.body = body
          env.request_headers = { "Content-Type" => "application/json" }
        end
      end
    end
  end
end
