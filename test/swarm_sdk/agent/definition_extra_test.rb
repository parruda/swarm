# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class AgentDefinitionExtraTest < Minitest::Test
    # Test name validation - name with @ character
    def test_name_with_at_symbol_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :"agent@instance",
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
          },
        )
      end

      assert_match(/cannot contain '@' character/, error.message)
      assert_match(/reserved for delegation instance naming/, error.message)
    end

    # Test directories (plural) configuration error
    def test_directories_plural_raises_breaking_change_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            directories: [".", "./lib"],
            system_prompt: "Test prompt",
          },
        )
      end

      assert_match(/directories.*plural.*no longer supported/i, error.message)
      assert_match(/Change 'directories:' to 'directory:'/i, error.message)
      assert_match(/permissions/i, error.message)
    end

    # Test headers are stringified
    def test_headers_are_stringified
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          headers: {
            authorization: "Bearer token",
            content_type: "application/json",
          },
        },
      )

      assert_equal("Bearer token", agent_def.headers["authorization"])
      assert_equal("application/json", agent_def.headers["content_type"])
      refute(agent_def.headers.key?(:authorization))
    end

    # Test bypass_permissions configuration
    def test_bypass_permissions_defaults_to_false
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      refute(agent_def.bypass_permissions)
    end

    def test_bypass_permissions_can_be_set
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          bypass_permissions: true,
        },
      )

      assert(agent_def.bypass_permissions)
    end

    # Test max_concurrent_tools configuration
    def test_max_concurrent_tools_defaults_to_nil
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_nil(agent_def.max_concurrent_tools)
    end

    def test_max_concurrent_tools_can_be_set
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          max_concurrent_tools: 5,
        },
      )

      assert_equal(5, agent_def.max_concurrent_tools)
    end

    # Test assume_model_exists always true
    def test_assume_model_exists_always_true
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert(agent_def.assume_model_exists)
    end

    # Test disable_default_tools variations
    def test_disable_default_tools_with_true
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Custom prompt",
          directory: ".",
          disable_default_tools: true,
        },
      )

      assert(agent_def.disable_default_tools)
      assert_equal("Custom prompt", agent_def.system_prompt)
    end

    def test_disable_default_tools_with_array
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Custom prompt",
          directory: ".",
          disable_default_tools: [:Think, :TodoWrite],
        },
      )

      assert_equal([:Think, :TodoWrite], agent_def.disable_default_tools)
    end

    # Test coding_agent variations
    def test_coding_agent_defaults_to_false
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      refute(agent_def.coding_agent)
    end

    def test_coding_agent_can_be_true
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Custom prompt",
          directory: ".",
          coding_agent: true,
        },
      )

      assert(agent_def.coding_agent)
      assert_includes(agent_def.system_prompt, "You are an AI agent designed to help users")
      assert_includes(agent_def.system_prompt, "Custom prompt")
    end

    def test_coding_agent_true_without_custom_prompt
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: true,
        },
      )

      assert_includes(agent_def.system_prompt, "You are an AI agent designed to help users")
      refute_includes(agent_def.system_prompt, "<%= cwd %>")
    end

    def test_coding_agent_true_with_empty_prompt
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "   ",
          directory: ".",
          coding_agent: true,
        },
      )

      # Empty/whitespace-only custom prompt should still get base prompt
      assert_includes(agent_def.system_prompt, "You are an AI agent designed to help users")
    end

    # Test shared_across_delegations
    def test_shared_across_delegations_defaults_to_false
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      refute(agent_def.shared_across_delegations)
    end

    def test_shared_across_delegations_can_be_set
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          shared_across_delegations: true,
        },
      )

      assert(agent_def.shared_across_delegations)
    end

    # Test memory configuration parsing
    # NOTE: memory_enabled? tests removed - that functionality is now in SwarmMemory plugin
    # See test/swarm_memory/integration/sdk_plugin_test.rb for storage_enabled? tests

    # Test tools parsing with permissions
    def test_tools_with_symbol
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [:Read],
        },
      )

      assert_equal([{ name: :Read, permissions: nil }], agent_def.tools)
    end

    def test_tools_with_string
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: ["Read"],
        },
      )

      assert_equal([{ name: :Read, permissions: nil }], agent_def.tools)
    end

    def test_tools_with_inline_permissions
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [{ Read: { allowed_paths: ["**/*.rb"] } }],
        },
      )

      assert_equal(
        [{ name: :Read, permissions: { allowed_paths: ["**/*.rb"] } }],
        agent_def.tools,
      )
    end

    def test_tools_with_parsed_format
      # Already parsed format should pass through
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [{ name: :Read, permissions: { allowed_paths: ["**/*.rb"] } }],
        },
      )

      assert_equal(
        [{ name: :Read, permissions: { allowed_paths: ["**/*.rb"] } }],
        agent_def.tools,
      )
    end

    def test_tools_with_default_permissions
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [:Read],
          default_permissions: { Read: { allowed_paths: ["**/*.txt"] } },
        },
      )

      assert_equal(
        [{ name: :Read, permissions: { allowed_paths: ["**/*.txt"] } }],
        agent_def.tools,
      )
    end

    def test_tools_with_agent_permissions_override_defaults
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [:Read],
          default_permissions: { Read: { allowed_paths: ["**/*.txt"] } },
          permissions: { Read: { allowed_paths: ["**/*.rb"] } },
        },
      )

      # Agent permissions override defaults
      assert_equal(
        [{ name: :Read, permissions: { allowed_paths: ["**/*.rb"] } }],
        agent_def.tools,
      )
    end

    def test_tools_invalid_specification_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
            tools: [123], # Invalid tool type
          },
        )
      end

      assert_match(/invalid tool specification/i, error.message)
    end

    # Test default write permissions injection
    def test_write_tool_gets_default_permissions
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [:Write],
        },
      )

      assert_equal(
        [{ name: :Write, permissions: { allowed_paths: ["**/*"] } }],
        agent_def.tools,
      )
    end

    def test_edit_tool_gets_default_permissions
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [:Edit],
        },
      )

      assert_equal(
        [{ name: :Edit, permissions: { allowed_paths: ["**/*"] } }],
        agent_def.tools,
      )
    end

    def test_multi_edit_tool_gets_default_permissions
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [:MultiEdit],
        },
      )

      assert_equal(
        [{ name: :MultiEdit, permissions: { allowed_paths: ["**/*"] } }],
        agent_def.tools,
      )
    end

    def test_write_tool_with_explicit_permissions_not_overridden
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          tools: [{ Write: { allowed_paths: ["lib/**/*"] } }],
        },
      )

      # Explicit permissions should not be overridden
      assert_equal(
        [{ name: :Write, permissions: { allowed_paths: ["lib/**/*"] } }],
        agent_def.tools,
      )
    end

    # Test hooks parsing
    def test_hooks_with_nil_returns_empty_hash
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          hooks: nil,
        },
      )

      assert_empty(agent_def.hooks)
    end

    def test_hooks_with_empty_hash_returns_empty_hash
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          hooks: {},
        },
      )

      assert_empty(agent_def.hooks)
    end

    def test_hooks_with_dsl_format_passed_through
      hook_def = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: "Write",
        proc: ->(_ctx) { puts "Hook" },
      )

      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          hooks: { pre_tool_use: [hook_def] },
        },
      )

      assert_equal({ pre_tool_use: [hook_def] }, agent_def.hooks)
    end

    def test_hooks_with_yaml_format
      hooks_config = {
        pre_tool_use: [
          {
            type: "command",
            command: "validate.sh",
            matcher: "Write|Edit",
          },
        ],
      }

      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          hooks: hooks_config,
        },
      )

      # YAML hooks are validated but passed through raw
      assert_equal(hooks_config, agent_def.hooks)
    end

    def test_hooks_with_invalid_event_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
            hooks: {
              invalid_event: [
                { type: "command", command: "test.sh" },
              ],
            },
          },
        )
      end

      assert_match(/invalid hook event/i, error.message)
      assert_match(/valid events:/i, error.message)
    end

    def test_hooks_with_missing_type_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
            hooks: {
              pre_tool_use: [
                { command: "test.sh" }, # Missing type
              ],
            },
          },
        )
      end

      assert_match(/missing 'type' field/i, error.message)
    end

    def test_hooks_with_command_type_missing_command_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
            hooks: {
              pre_tool_use: [
                { type: "command" }, # Missing command
              ],
            },
          },
        )
      end

      assert_match(/missing 'command' field/i, error.message)
    end

    # Test validate method (non-fatal warnings)
    def test_validate_returns_empty_for_valid_model
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          model: "gpt-4o-mini",
        },
      )

      warnings = agent_def.validate

      assert_empty(warnings)
    end

    def test_validate_returns_warning_for_unknown_model
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          model: "nonexistent-model",
        },
      )

      warnings = agent_def.validate

      assert_equal(1, warnings.length)
      warning = warnings.first

      assert_equal(:model_not_found, warning[:type])
      assert_equal(:test_agent, warning[:agent])
      assert_equal("nonexistent-model", warning[:model])
      assert_includes(warning[:error_message], "Unknown model")
    end

    def test_validate_with_model_alias
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          model: "sonnet", # Alias that should resolve
        },
      )

      # Should not return warning if alias resolves correctly
      warnings = agent_def.validate

      # Result depends on whether "sonnet" alias exists in models.json
      # Test just verifies the method runs without error
      assert_kind_of(Array, warnings)
    end

    # Test to_h with all fields
    def test_to_h_includes_all_configuration
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          model: "gpt-5",
          context_window: 128000,
          system_prompt: "Test prompt",
          provider: "openai",
          base_url: "https://api.openai.com",
          api_version: "v1/responses",
          parameters: { temperature: 0.5 },
          headers: { authorization: "Bearer token" },
          timeout: 600,
          directory: ".",
          tools: [:Read],
          delegates_to: [:backend],
          mcp_servers: [{ type: :stdio }],
          bypass_permissions: true,
          disable_default_tools: [:Think],
          coding_agent: true,
          max_concurrent_tools: 3,
          shared_across_delegations: true,
          default_permissions: { Read: { allowed_paths: ["**/*"] } },
          permissions: { Write: { allowed_paths: ["lib/**/*"] } },
        },
      )

      hash = agent_def.to_h

      assert_equal(:test_agent, hash[:name])
      assert_equal("Test agent", hash[:description])
      assert_equal("gpt-5", hash[:model])
      assert_equal(128000, hash[:context_window])
      assert_equal("openai", hash[:provider])
      assert_equal("https://api.openai.com", hash[:base_url])
      assert_equal("v1/responses", hash[:api_version])
      assert_equal({ temperature: 0.5 }, hash[:parameters])
      assert_equal({ "authorization" => "Bearer token" }, hash[:headers])
      assert_equal(600, hash[:timeout])
      assert(hash[:bypass_permissions])
      assert_equal([:Think], hash[:disable_default_tools])
      assert(hash[:coding_agent])
      assert(hash[:assume_model_exists])
      assert_equal(3, hash[:max_concurrent_tools])
      assert(hash[:shared_across_delegations])
      assert_equal({ Read: { allowed_paths: ["**/*"] } }, hash[:default_permissions])
      assert_equal({ Write: { allowed_paths: ["lib/**/*"] } }, hash[:permissions])
    end

    # Test API version with different compatible providers
    def test_api_version_with_deepseek_provider
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "deepseek",
          api_version: "v1/chat/completions",
        },
      )

      assert_equal("v1/chat/completions", agent_def.api_version)
    end

    def test_api_version_with_perplexity_provider
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "perplexity",
          api_version: "v1/responses",
        },
      )

      assert_equal("v1/responses", agent_def.api_version)
    end

    def test_api_version_with_mistral_provider
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "mistral",
          api_version: "v1/chat/completions",
        },
      )

      assert_equal("v1/chat/completions", agent_def.api_version)
    end

    def test_api_version_with_openrouter_provider
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "openrouter",
          api_version: "v1/responses",
        },
      )

      assert_equal("v1/responses", agent_def.api_version)
    end

    # Test context_window configuration
    def test_context_window_defaults_to_nil
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_nil(agent_def.context_window)
    end

    def test_context_window_can_be_set
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          context_window: 200000,
        },
      )

      assert_equal(200000, agent_def.context_window)
    end

    # Test delegates_to array handling
    def test_delegates_to_with_duplicates_deduplicates
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          delegates_to: [:backend, :frontend, :backend],
        },
      )

      assert_equal([:backend, :frontend], agent_def.delegates_to)
    end

    def test_delegates_to_converts_strings_to_symbols
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          delegates_to: ["backend", "frontend"],
        },
      )

      assert_equal([:backend, :frontend], agent_def.delegates_to)
    end

    # Test render_non_coding_base_prompt includes environment info
    def test_non_coding_base_prompt_includes_date
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: false,
        },
      )

      assert_includes(agent_def.system_prompt, "today-date")
      assert_includes(agent_def.system_prompt, Time.now.strftime("%Y-%m-%d"))
    end

    def test_non_coding_base_prompt_includes_environment
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: false,
        },
      )

      assert_includes(agent_def.system_prompt, "Current Environment")
      assert_includes(agent_def.system_prompt, "Working directory:")
      assert_includes(agent_def.system_prompt, "Platform:")
    end

    # Test ERB rendering in base system prompt
    def test_base_system_prompt_erb_rendering
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: true,
        },
      )

      # ERB should be rendered, not left as template
      refute_includes(agent_def.system_prompt, "<%= cwd %>")
      refute_includes(agent_def.system_prompt, "<%= platform %>")
    end

    # Test mcp_servers array handling
    def test_mcp_servers_defaults_to_empty_array
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_empty(agent_def.mcp_servers)
    end

    def test_mcp_servers_accepts_single_hash
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          mcp_servers: [{ type: :stdio, command: "test" }],
        },
      )

      assert_equal([{ type: :stdio, command: "test" }], agent_def.mcp_servers)
    end

    # Test parameters defaults to empty hash
    def test_parameters_defaults_to_empty_hash
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_empty(agent_def.parameters)
    end

    # Test headers defaults to empty hash
    def test_headers_defaults_to_empty_hash
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_empty(agent_def.headers)
    end

    # Test plugin prompt contributions (using capture_io to suppress output)
    def test_plugin_prompt_contributions
      # Create a mock plugin instance
      plugin = Class.new(SwarmSDK::Plugin) do
        def name
          :test_plugin
        end

        def tools
          []
        end

        def storage_enabled?(agent_def)
          true
        end

        def system_prompt_contribution(agent_definition:, storage:)
          "Test plugin contribution"
        end
      end.new

      begin
        PluginRegistry.register(plugin)

        agent_def = Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Custom prompt",
            directory: ".",
          },
        )

        assert_includes(agent_def.system_prompt, "Custom prompt")
        assert_includes(agent_def.system_prompt, "Test plugin contribution")
      ensure
        PluginRegistry.clear
      end
    end

    def test_plugin_prompt_contributions_with_empty_contribution
      # Create a mock plugin that returns empty string
      plugin = Class.new(SwarmSDK::Plugin) do
        def name
          :test_plugin
        end

        def tools
          []
        end

        def storage_enabled?(agent_def)
          true
        end

        def system_prompt_contribution(agent_definition:, storage:)
          ""
        end
      end.new

      begin
        PluginRegistry.register(plugin)

        agent_def = Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Custom prompt",
            directory: ".",
          },
        )

        # Empty contribution should not be included
        assert_equal(0, agent_def.system_prompt.scan("Test plugin").length)
      ensure
        PluginRegistry.clear
      end
    end

    def test_plugin_prompt_contributions_when_storage_disabled
      # Create a mock plugin with storage disabled
      plugin = Class.new(SwarmSDK::Plugin) do
        def name
          :test_plugin
        end

        def tools
          []
        end

        def storage_enabled?(agent_def)
          false
        end

        def system_prompt_contribution(agent_definition:, storage:)
          "Should not appear"
        end
      end.new

      begin
        PluginRegistry.register(plugin)

        agent_def = Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Custom prompt",
            directory: ".",
          },
        )

        # Plugin contribution should not be included when storage disabled
        refute_includes(agent_def.system_prompt, "Should not appear")
      ensure
        PluginRegistry.clear
      end
    end
  end
end
