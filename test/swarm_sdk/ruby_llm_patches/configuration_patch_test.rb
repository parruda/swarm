# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class ConfigurationPatchTest < Minitest::Test
      def setup
        @config = RubyLLM::Configuration.new
      end

      # ========== anthropic_api_base ==========

      def test_anthropic_api_base_defaults_to_nil
        assert_nil(@config.anthropic_api_base)
      end

      def test_anthropic_api_base_is_configurable
        @config.anthropic_api_base = "https://custom.anthropic.com"

        assert_equal("https://custom.anthropic.com", @config.anthropic_api_base)
      end

      # ========== read_timeout ==========

      def test_read_timeout_defaults_to_nil
        assert_nil(@config.read_timeout)
      end

      def test_read_timeout_is_configurable
        @config.read_timeout = 600

        assert_equal(600, @config.read_timeout)
      end

      # ========== open_timeout ==========

      def test_open_timeout_defaults_to_30
        assert_equal(30, @config.open_timeout)
      end

      def test_open_timeout_is_configurable
        @config.open_timeout = 60

        assert_equal(60, @config.open_timeout)
      end

      # ========== write_timeout ==========

      def test_write_timeout_defaults_to_30
        assert_equal(30, @config.write_timeout)
      end

      def test_write_timeout_is_configurable
        @config.write_timeout = 120

        assert_equal(120, @config.write_timeout)
      end

      # ========== Original config options preserved ==========

      def test_request_timeout_still_exists
        assert_equal(300, @config.request_timeout)
      end

      def test_max_retries_still_exists
        assert_equal(3, @config.max_retries)
      end

      def test_openai_api_key_still_configurable
        @config.openai_api_key = "test-key"

        assert_equal("test-key", @config.openai_api_key)
      end

      # ========== Anthropic Provider Base URL ==========

      def test_anthropic_provider_uses_default_base_url
        config = RubyLLM::Configuration.new
        config.anthropic_api_key = "test-key"
        provider = RubyLLM::Providers::Anthropic.new(config)

        assert_equal("https://api.anthropic.com", provider.api_base)
      end

      def test_anthropic_provider_uses_custom_base_url
        config = RubyLLM::Configuration.new
        config.anthropic_api_key = "test-key"
        config.anthropic_api_base = "https://custom.anthropic.example.com"
        provider = RubyLLM::Providers::Anthropic.new(config)

        assert_equal("https://custom.anthropic.example.com", provider.api_base)
      end

      # ========== Configuration via RubyLLM.configure ==========

      def test_configure_block_sets_anthropic_api_base
        RubyLLM.configure do |config|
          config.anthropic_api_base = "https://configured.example.com"
        end

        assert_equal("https://configured.example.com", RubyLLM.config.anthropic_api_base)
      ensure
        RubyLLM.config.anthropic_api_base = nil
      end

      def test_configure_block_sets_read_timeout
        RubyLLM.configure do |config|
          config.read_timeout = 500
        end

        assert_equal(500, RubyLLM.config.read_timeout)
      ensure
        RubyLLM.config.read_timeout = nil
      end
    end
  end
end
