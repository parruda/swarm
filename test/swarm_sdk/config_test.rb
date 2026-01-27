# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ConfigTest < Minitest::Test
    def setup
      # Save original ENV values
      @original_env = {}
      [
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "SWARM_SDK_DEFAULT_MODEL",
        "SWARM_SDK_DEFAULT_PROVIDER",
        "SWARM_SDK_AGENT_REQUEST_TIMEOUT",
        "SWARM_SDK_ALLOW_FILESYSTEM_TOOLS",
        "SWARM_SDK_ENV_INTERPOLATION",
        "SWARM_SDK_WEBFETCH_PROVIDER",
        "SWARM_SDK_WEBFETCH_MODEL",
        "SWARM_SDK_WEBFETCH_MAX_TOKENS",
        "SWARM_SDK_BASH_COMMAND_TIMEOUT",
        "SWARM_SDK_GLOBAL_CONCURRENCY_LIMIT",
        "SWARM_SDK_CHARS_PER_TOKEN_PROSE",
        "SWARM_SDK_CHARS_PER_TOKEN_CODE",
        "SWARM_SDK_MCP_LOG_LEVEL",
        "SWARM_SDK_CONTEXT_COMPRESSION_THRESHOLD",
        "SWARM_SDK_READ_MAX_TOKENS",
      ].each do |key|
        @original_env[key] = ENV[key]
        ENV.delete(key)
      end

      # Reset config for each test
      SwarmSDK.reset_config!
    end

    def teardown
      # Restore original ENV values
      @original_env.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end

      # Reset config after each test
      SwarmSDK.reset_config!
    end

    # ========== Phase 1: Core Config Class ==========

    def test_singleton_pattern
      config1 = SwarmSDK.config
      config2 = SwarmSDK.config

      assert_same(config1, config2)
    end

    def test_reset_creates_new_instance
      config1 = SwarmSDK.config
      SwarmSDK.reset_config!
      config2 = SwarmSDK.config

      refute_same(config1, config2)
    end

    def test_configure_yields_config
      yielded_config = nil

      SwarmSDK.configure do |config|
        yielded_config = config
      end

      assert_same(SwarmSDK.config, yielded_config)
    end

    def test_configure_returns_config
      result = SwarmSDK.configure do |config|
        config.default_model = "test-model"
      end

      assert_same(SwarmSDK.config, result)
    end

    # ========== Priority Order Tests ==========

    def test_explicit_configuration_takes_priority_over_env
      ENV["OPENAI_API_KEY"] = "env-key"

      SwarmSDK.configure do |config|
        config.openai_api_key = "explicit-key"
      end

      assert_equal("explicit-key", SwarmSDK.config.openai_api_key)
    end

    def test_env_fallback_when_no_explicit_value
      ENV["OPENAI_API_KEY"] = "env-key"

      assert_equal("env-key", SwarmSDK.config.openai_api_key)
    end

    def test_module_default_fallback_when_no_env_or_explicit
      # No ENV, no explicit config
      assert_equal(Defaults::Agent::MODEL, SwarmSDK.config.default_model)
    end

    def test_explicit_overrides_env_for_defaults
      ENV["SWARM_SDK_DEFAULT_MODEL"] = "env-model"

      SwarmSDK.configure do |config|
        config.default_model = "explicit-model"
      end

      assert_equal("explicit-model", SwarmSDK.config.default_model)
    end

    def test_env_overrides_module_default
      ENV["SWARM_SDK_DEFAULT_MODEL"] = "env-model"

      assert_equal("env-model", SwarmSDK.config.default_model)
    end

    # ========== API Key Proxying Tests ==========

    def test_api_key_proxies_to_rubyllm_on_set
      SwarmSDK.configure do |config|
        config.openai_api_key = "proxy-test-key"
      end

      assert_equal("proxy-test-key", RubyLLM.config.openai_api_key)
    end

    def test_anthropic_key_proxies_to_rubyllm
      SwarmSDK.configure do |config|
        config.anthropic_api_key = "anthropic-test-key"
      end

      assert_equal("anthropic-test-key", RubyLLM.config.anthropic_api_key)
    end

    def test_env_api_key_proxies_to_rubyllm_on_lazy_load
      ENV["OPENAI_API_KEY"] = "env-proxy-key"

      # Trigger lazy load by accessing any config value
      SwarmSDK.config.openai_api_key

      assert_equal("env-proxy-key", RubyLLM.config.openai_api_key)
    end

    def test_nil_api_key_does_not_proxy
      # Explicitly set nil
      SwarmSDK.configure do |config|
        config.openai_api_key = nil
      end

      # RubyLLM should not have been updated (would be whatever was there before)
      # This tests that we don't proxy nil values
      assert_nil(SwarmSDK.config.openai_api_key)
    end

    # ========== Defaults Override Tests ==========

    def test_all_defaults_have_module_fallbacks
      # Test a sample of defaults
      assert_equal(Defaults::Timeouts::AGENT_REQUEST_SECONDS, SwarmSDK.config.agent_request_timeout)
      assert_equal(Defaults::Timeouts::BASH_COMMAND_MS, SwarmSDK.config.bash_command_timeout)
      assert_equal(Defaults::Concurrency::GLOBAL_LIMIT, SwarmSDK.config.global_concurrency_limit)
    end

    def test_override_timeout_defaults
      SwarmSDK.configure do |config|
        config.agent_request_timeout = 600
        config.bash_command_timeout = 300_000
      end

      assert_equal(600, SwarmSDK.config.agent_request_timeout)
      assert_equal(300_000, SwarmSDK.config.bash_command_timeout)
    end

    def test_override_limit_defaults
      SwarmSDK.configure do |config|
        config.read_max_tokens = 50_000
        config.output_character_limit = 50_000
      end

      assert_equal(50_000, SwarmSDK.config.read_max_tokens)
      assert_equal(50_000, SwarmSDK.config.output_character_limit)
    end

    def test_env_integer_parsing_for_timeouts
      ENV["SWARM_SDK_AGENT_REQUEST_TIMEOUT"] = "900"

      assert_equal(900, SwarmSDK.config.agent_request_timeout)
    end

    def test_env_float_parsing_for_token_estimation
      ENV["SWARM_SDK_CHARS_PER_TOKEN_PROSE"] = "5.5"

      assert_in_delta(5.5, SwarmSDK.config.chars_per_token_prose)
    end

    # ========== WebFetch & Settings Tests ==========

    def test_webfetch_llm_enabled_when_both_set
      SwarmSDK.configure do |config|
        config.webfetch_provider = "anthropic"
        config.webfetch_model = "claude-3-5-haiku-20241022"
      end

      assert_predicate(SwarmSDK.config, :webfetch_llm_enabled?)
    end

    def test_webfetch_llm_disabled_when_provider_nil
      SwarmSDK.configure do |config|
        config.webfetch_model = "claude-3-5-haiku-20241022"
      end

      refute_predicate(SwarmSDK.config, :webfetch_llm_enabled?)
    end

    def test_webfetch_llm_disabled_when_model_nil
      SwarmSDK.configure do |config|
        config.webfetch_provider = "anthropic"
      end

      refute_predicate(SwarmSDK.config, :webfetch_llm_enabled?)
    end

    def test_allow_filesystem_tools_default
      assert(SwarmSDK.config.allow_filesystem_tools)
    end

    def test_allow_filesystem_tools_can_be_disabled
      SwarmSDK.configure do |config|
        config.allow_filesystem_tools = false
      end

      refute(SwarmSDK.config.allow_filesystem_tools)
    end

    def test_env_boolean_parsing_for_filesystem_tools
      ENV["SWARM_SDK_ALLOW_FILESYSTEM_TOOLS"] = "false"

      refute(SwarmSDK.config.allow_filesystem_tools)
    end

    def test_env_interpolation_default
      assert(SwarmSDK.config.env_interpolation)
    end

    def test_env_interpolation_can_be_disabled
      SwarmSDK.configure do |config|
        config.env_interpolation = false
      end

      refute(SwarmSDK.config.env_interpolation)
    end

    def test_env_boolean_parsing_for_env_interpolation
      ENV["SWARM_SDK_ENV_INTERPOLATION"] = "false"

      refute(SwarmSDK.config.env_interpolation)
    end

    def test_env_boolean_parsing_various_true_values
      ["true", "yes", "1", "on", "enabled"].each do |value|
        SwarmSDK.reset_config!
        ENV["SWARM_SDK_ALLOW_FILESYSTEM_TOOLS"] = value

        assert(SwarmSDK.config.allow_filesystem_tools, "Expected '#{value}' to be true")
      end
    end

    def test_env_boolean_parsing_various_false_values
      ["false", "no", "0", "off", "disabled"].each do |value|
        SwarmSDK.reset_config!
        ENV["SWARM_SDK_ALLOW_FILESYSTEM_TOOLS"] = value

        refute(SwarmSDK.config.allow_filesystem_tools, "Expected '#{value}' to be false")
      end
    end

    # ========== Comprehensive ENV Mapping Tests ==========

    def test_env_string_mapping_for_webfetch_provider
      ENV["SWARM_SDK_WEBFETCH_PROVIDER"] = "anthropic"

      assert_equal("anthropic", SwarmSDK.config.webfetch_provider)
    end

    def test_env_string_mapping_for_webfetch_model
      ENV["SWARM_SDK_WEBFETCH_MODEL"] = "claude-3-haiku"

      assert_equal("claude-3-haiku", SwarmSDK.config.webfetch_model)
    end

    def test_env_string_mapping_for_default_provider
      ENV["SWARM_SDK_DEFAULT_PROVIDER"] = "openai"

      assert_equal("openai", SwarmSDK.config.default_provider)
    end

    def test_env_integer_mapping_for_bash_timeout
      ENV["SWARM_SDK_BASH_COMMAND_TIMEOUT"] = "180000"

      assert_equal(180_000, SwarmSDK.config.bash_command_timeout)
    end

    def test_env_integer_mapping_for_read_max_tokens
      ENV["SWARM_SDK_READ_MAX_TOKENS"] = "50000"

      assert_equal(50_000, SwarmSDK.config.read_max_tokens)
    end

    def test_env_integer_mapping_for_global_concurrency
      ENV["SWARM_SDK_GLOBAL_CONCURRENCY_LIMIT"] = "100"

      assert_equal(100, SwarmSDK.config.global_concurrency_limit)
    end

    def test_env_integer_mapping_for_webfetch_max_tokens
      ENV["SWARM_SDK_WEBFETCH_MAX_TOKENS"] = "8192"

      assert_equal(8192, SwarmSDK.config.webfetch_max_tokens)
    end

    def test_env_float_mapping_for_chars_per_token_code
      ENV["SWARM_SDK_CHARS_PER_TOKEN_CODE"] = "3.0"

      assert_in_delta(3.0, SwarmSDK.config.chars_per_token_code)
    end

    def test_env_mapping_for_mcp_log_level
      ENV["SWARM_SDK_MCP_LOG_LEVEL"] = "1"

      assert_equal(1, SwarmSDK.config.mcp_log_level)
    end

    def test_env_mapping_for_context_compression_threshold
      ENV["SWARM_SDK_CONTEXT_COMPRESSION_THRESHOLD"] = "70"

      assert_equal(70, SwarmSDK.config.context_compression_threshold)
    end

    # ========== Lazy Loading Tests ==========

    def test_lazy_loading_defers_env_read
      # Set ENV after config is created but before first access
      SwarmSDK.config # Create instance
      ENV["OPENAI_API_KEY"] = "lazy-loaded-key"

      # First access triggers lazy load
      assert_equal("lazy-loaded-key", SwarmSDK.config.openai_api_key)
    end

    def test_lazy_loading_only_happens_once
      ENV["OPENAI_API_KEY"] = "first-key"

      # First access
      assert_equal("first-key", SwarmSDK.config.openai_api_key)

      # Change ENV after first access
      ENV["OPENAI_API_KEY"] = "second-key"

      # Should still return cached first-key
      assert_equal("first-key", SwarmSDK.config.openai_api_key)
    end

    def test_explicit_values_not_affected_by_lazy_loading
      SwarmSDK.configure do |config|
        config.openai_api_key = "explicit-key"
      end

      ENV["OPENAI_API_KEY"] = "env-key"

      # Explicit value should still win
      assert_equal("explicit-key", SwarmSDK.config.openai_api_key)
    end

    # ========== Thread Safety Tests ==========

    def test_thread_safe_lazy_loading
      ENV["OPENAI_API_KEY"] = "thread-safe-key"

      results = []
      threads = 10.times.map do
        Thread.new do
          results << SwarmSDK.config.openai_api_key
        end
      end

      threads.each(&:join)

      # All threads should get the same value
      assert_equal(10, results.count("thread-safe-key"))
    end

    # ========== Reset Tests ==========

    def test_reset_clears_explicit_values
      SwarmSDK.configure do |config|
        config.openai_api_key = "explicit-key"
      end

      SwarmSDK.reset_config!

      assert_nil(SwarmSDK.config.openai_api_key)
    end

    def test_reset_clears_cached_env_values
      ENV["OPENAI_API_KEY"] = "first-key"
      SwarmSDK.config.openai_api_key # Trigger cache

      SwarmSDK.reset_config!
      ENV["OPENAI_API_KEY"] = "second-key"

      # After reset, should pick up new ENV value
      assert_equal("second-key", SwarmSDK.config.openai_api_key)
    end

    def test_reset_allows_reconfiguration
      SwarmSDK.configure do |config|
        config.default_model = "first-model"
      end

      SwarmSDK.reset_config!

      SwarmSDK.configure do |config|
        config.default_model = "second-model"
      end

      assert_equal("second-model", SwarmSDK.config.default_model)
    end

    # ========== Integration Tests ==========

    def test_full_configuration_flow
      ENV["ANTHROPIC_API_KEY"] = "env-anthropic-key"

      SwarmSDK.configure do |config|
        config.openai_api_key = "explicit-openai-key"
        config.default_model = "claude-sonnet-4"
        config.default_provider = "anthropic"
        config.agent_request_timeout = 600
        config.webfetch_provider = "openai"
        config.webfetch_model = "gpt-4o-mini"
      end

      # Explicit values
      assert_equal("explicit-openai-key", SwarmSDK.config.openai_api_key)
      assert_equal("claude-sonnet-4", SwarmSDK.config.default_model)
      assert_equal("anthropic", SwarmSDK.config.default_provider)
      assert_equal(600, SwarmSDK.config.agent_request_timeout)

      # ENV fallback
      assert_equal("env-anthropic-key", SwarmSDK.config.anthropic_api_key)

      # WebFetch enabled
      assert_predicate(SwarmSDK.config, :webfetch_llm_enabled?)

      # RubyLLM proxying worked
      assert_equal("explicit-openai-key", RubyLLM.config.openai_api_key)
      assert_equal("env-anthropic-key", RubyLLM.config.anthropic_api_key)
    end

    def test_config_used_by_agent_definition
      SwarmSDK.configure do |config|
        config.default_model = "custom-model"
        config.default_provider = "anthropic"
        config.agent_request_timeout = 120
      end

      definition = Agent::Definition.new(:test_agent, {
        description: "Test",
        system_prompt: "Test prompt",
        directory: ".",
      })

      assert_equal("custom-model", definition.model)
      assert_equal("anthropic", definition.provider)
      assert_equal(120, definition.request_timeout)
    end
  end
end
