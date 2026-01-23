# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class ConnectionPatchTest < Minitest::Test
      # ========== Connection.basic ==========

      def test_basic_returns_faraday_connection
        conn = RubyLLM::Connection.basic

        assert_instance_of(Faraday::Connection, conn)
      end

      def test_basic_uses_net_http_adapter
        conn = RubyLLM::Connection.basic

        # In Faraday 2.x, adapter is stored separately from middleware handlers
        adapter = conn.builder.adapter

        assert(adapter, "Expected an adapter to be configured")
        adapter_name = adapter.klass.name
        has_net_http = adapter_name.include?("NetHttp") || adapter_name.include?("Net::HTTP")

        assert(has_net_http, "Expected net_http adapter, got: #{adapter_name}")
      end

      def test_basic_yields_to_block
        yielded = false
        RubyLLM::Connection.basic { |_f| yielded = true }

        assert(yielded)
      end

      def test_basic_has_raise_error_middleware
        conn = RubyLLM::Connection.basic

        handler_names = conn.builder.handlers.map do |h|
          h.klass.name
        rescue
          h.name
        end
        has_raise_error = handler_names.any? { |name| name.to_s.include?("RaiseError") }

        assert(has_raise_error, "Expected raise_error middleware, got handlers: #{handler_names}")
      end

      # ========== Granular Timeouts ==========

      def test_setup_timeout_sets_request_timeout
        config = RubyLLM::Configuration.new
        config.request_timeout = 120
        config.anthropic_api_key = "test-key"

        provider = RubyLLM::Providers::Anthropic.new(config)
        conn = provider.connection

        assert_equal(120, conn.connection.options.timeout)
      end

      def test_setup_timeout_sets_open_timeout
        config = RubyLLM::Configuration.new
        config.open_timeout = 45
        config.anthropic_api_key = "test-key"

        provider = RubyLLM::Providers::Anthropic.new(config)
        conn = provider.connection

        assert_equal(45, conn.connection.options.open_timeout)
      end

      def test_setup_timeout_sets_write_timeout
        config = RubyLLM::Configuration.new
        config.write_timeout = 60
        config.anthropic_api_key = "test-key"

        provider = RubyLLM::Providers::Anthropic.new(config)
        conn = provider.connection

        assert_equal(60, conn.connection.options.write_timeout)
      end

      def test_setup_timeout_read_timeout_defaults_to_request_timeout
        config = RubyLLM::Configuration.new
        config.request_timeout = 200
        config.read_timeout = nil
        config.anthropic_api_key = "test-key"

        provider = RubyLLM::Providers::Anthropic.new(config)
        conn = provider.connection

        assert_equal(200, conn.connection.options.read_timeout)
      end

      def test_setup_timeout_read_timeout_overrides_request_timeout
        config = RubyLLM::Configuration.new
        config.request_timeout = 200
        config.read_timeout = 500
        config.anthropic_api_key = "test-key"

        provider = RubyLLM::Providers::Anthropic.new(config)
        conn = provider.connection

        assert_equal(500, conn.connection.options.read_timeout)
      end
    end
  end
end
