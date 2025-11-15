# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class AgentDefinitionTest < Minitest::Test
    def test_initialization_with_required_fields
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "You are a test agent",
          directory: ".",
        },
      )

      assert_equal(:test_agent, agent_def.name)
      assert_equal("Test agent", agent_def.description)
      # Default is coding_agent: false, default tools enabled
      # So it includes environment info + custom prompt
      # TodoWrite/Scratchpad instructions are now in tool descriptions, not system prompt
      assert_includes(agent_def.system_prompt, "You are a test agent")
      assert_includes(agent_def.system_prompt, "Today's date")
      refute_includes(agent_def.system_prompt, "TodoWrite")
      assert_equal(File.expand_path("."), agent_def.directory)
    end

    def test_initialization_with_defaults
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_equal("gpt-5", agent_def.model)
      assert_equal("openai", agent_def.provider)
      assert_empty(agent_def.tools)
      assert_empty(agent_def.delegates_to)
      assert_empty(agent_def.mcp_servers)
    end

    def test_initialization_with_all_fields
      agent_def = Agent::Definition.new(
        :full_agent,
        {
          description: "Full agent",
          model: "claude-sonnet-4",
          system_prompt: "You are full",
          provider: "anthropic",
          base_url: "https://api.anthropic.com",
          parameters: {
            temperature: 0.7,
            max_tokens: 4000,
            reasoning: "high",
          },
          directory: ".",
          tools: [:Read, :Edit, :Bash],
          delegates_to: [:backend, :frontend],
          mcp_servers: [{ type: :stdio, command: "test" }],
        },
      )

      assert_equal("claude-sonnet-4", agent_def.model)
      assert_equal("anthropic", agent_def.provider)
      assert_in_delta(0.7, agent_def.parameters[:temperature])
      assert_equal(4000, agent_def.parameters[:max_tokens])
      assert_equal("https://api.anthropic.com", agent_def.base_url)
      assert_equal("high", agent_def.parameters[:reasoning])
      assert_equal(File.expand_path("."), agent_def.directory)
      assert_equal([{ name: :Read, permissions: nil }, { name: :Edit, permissions: { allowed_paths: ["**/*"] } }, { name: :Bash, permissions: nil }], agent_def.tools)
      assert_equal([:backend, :frontend], agent_def.delegates_to)
      assert_equal(1, agent_def.mcp_servers.length)
    end

    def test_missing_description_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            system_prompt: "Test prompt",
            directory: ".",
          },
        )
      end

      assert_match(/missing required 'description' field/i, error.message)
    end

    def test_missing_system_prompt_with_coding_agent_false_and_default_tools
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: false,
          # disable_default_tools defaults to nil (all tools enabled)
        },
      )

      # With coding_agent: false, default tools enabled, and no custom prompt
      # Should get environment info only (TodoWrite/Scratchpad info is in tool descriptions)
      refute_empty(agent_def.system_prompt)
      assert_includes(agent_def.system_prompt, "Today's date")
      assert_includes(agent_def.system_prompt, "Current Environment")
      refute_includes(agent_def.system_prompt, "TodoWrite")
      refute_includes(agent_def.system_prompt, "Scratchpad")
    end

    def test_missing_system_prompt_with_coding_agent_false_no_default_tools
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: false,
          disable_default_tools: true,
        },
      )

      # With coding_agent: false, disable_default_tools: true, and no custom prompt
      # Should be empty
      assert_equal("", agent_def.system_prompt)
    end

    def test_missing_system_prompt_with_coding_agent_true
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          directory: ".",
          coding_agent: true,
        },
      )

      # With coding_agent: true and no custom prompt, should use base prompt
      assert_includes(agent_def.system_prompt, "You are an AI agent designed to help users")
      refute_includes(agent_def.system_prompt, "<%= cwd %>")
    end

    def test_nonexistent_directory_raises_error
      error = assert_raises(ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: "/nonexistent/path",
          },
        )
      end

      assert_match(/directory.*does not exist/i, error.message)
    end

    def test_parse_directories_with_nil
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
        },
      )

      assert_equal(File.expand_path("."), agent_def.directory)
    end

    def test_parse_directories_with_single_string
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_equal(File.expand_path("."), agent_def.directory)
    end

    def test_parse_directory_with_dot
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      # Directory is expanded to absolute path
      assert_equal(File.expand_path("."), agent_def.directory)
    end

    def test_directory_is_expanded
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: "lib",
        },
      )

      # Directory should be expanded to absolute path
      assert_equal(File.expand_path("lib"), agent_def.directory)
    end

    def test_to_h_returns_complete_hash
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          model: "gpt-5",
          system_prompt: "Test prompt",
          provider: "openai",
          base_url: "https://api.openai.com",
          parameters: {
            temperature: 0.8,
            max_tokens: 2000,
            reasoning: "medium",
          },
          directory: ".",
          tools: [:Read],
          delegates_to: [:backend],
          mcp_servers: [{ type: :stdio }],
          coding_agent: false, # Explicit default
          disable_default_tools: true, # No default tools for exact prompt
        },
      )

      hash = agent_def.to_h

      assert_equal(:test_agent, hash[:name])
      assert_equal("Test agent", hash[:description])
      assert_equal("gpt-5", hash[:model])
      # With coding_agent: false, disable_default_tools: true → only custom prompt
      assert_equal("Test prompt", hash[:system_prompt])
      assert_equal("openai", hash[:provider])
      assert_in_delta(0.8, hash[:parameters][:temperature])
      assert_equal(2000, hash[:parameters][:max_tokens])
      assert_equal("https://api.openai.com", hash[:base_url])
      assert_equal("medium", hash[:parameters][:reasoning])
      assert_equal(agent_def.directory, hash[:directory])
      assert_equal([{ name: :Read, permissions: nil }], hash[:tools])
      assert_equal([:backend], hash[:delegates_to])
      assert_equal([{ type: :stdio }], hash[:mcp_servers])
    end

    def test_to_h_omits_nil_values
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      hash = agent_def.to_h

      # Has non-nil values
      assert(hash.key?(:name))
      assert(hash.key?(:description))
      assert(hash.key?(:system_prompt))

      # Omits nil values (compact removes them)
      refute(hash.key?(:temperature))
      refute(hash.key?(:max_tokens))
      refute(hash.key?(:base_url))
      refute(hash.key?(:reasoning))
    end

    def test_attr_readers
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_respond_to(agent_def, :name)
      assert_respond_to(agent_def, :description)
      assert_respond_to(agent_def, :model)
      assert_respond_to(agent_def, :directory)
      assert_respond_to(agent_def, :tools)
      assert_respond_to(agent_def, :delegates_to)
      assert_respond_to(agent_def, :system_prompt)
      assert_respond_to(agent_def, :provider)
      assert_respond_to(agent_def, :base_url)
      assert_respond_to(agent_def, :mcp_servers)
      assert_respond_to(agent_def, :parameters)
      assert_respond_to(agent_def, :timeout)
    end

    def test_default_timeout_constant
      assert_equal(300, Defaults::Timeouts::AGENT_REQUEST_SECONDS)
    end

    def test_timeout_defaults_to_300_seconds
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_equal(300, agent_def.timeout)
    end

    def test_timeout_can_be_customized
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          timeout: 600,
        },
      )

      assert_equal(600, agent_def.timeout)
    end

    def test_to_h_includes_timeout
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          timeout: 450,
        },
      )

      hash = agent_def.to_h

      assert_equal(450, hash[:timeout])
    end

    def test_api_version_with_openai_provider
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "openai",
          api_version: "v1/responses",
        },
      )

      assert_equal("v1/responses", agent_def.api_version)
    end

    def test_api_version_with_non_openai_provider_raises_error
      error = assert_raises(SwarmSDK::ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
            provider: "ollama",
            api_version: "v1/responses",
          },
        )
      end

      assert_match(/api_version can only be used with OpenAI-compatible providers/, error.message)
    end

    def test_api_version_with_invalid_value_raises_error
      error = assert_raises(SwarmSDK::ConfigurationError) do
        Agent::Definition.new(
          :test_agent,
          {
            description: "Test agent",
            system_prompt: "Test prompt",
            directory: ".",
            provider: "openai",
            api_version: "invalid",
          },
        )
      end

      assert_match(/invalid api_version/, error.message)
    end

    def test_api_version_with_chat_completions
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "openai",
          api_version: "v1/chat/completions",
        },
      )

      assert_equal("v1/chat/completions", agent_def.api_version)
    end

    def test_api_version_included_in_to_h
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "openai",
          api_version: "v1/responses",
        },
      )

      hash = agent_def.to_h

      assert_equal("v1/responses", hash[:api_version])
    end

    def test_api_version_omitted_from_to_h_when_nil
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          provider: "openai",
        },
      )

      hash = agent_def.to_h

      refute(hash.key?(:api_version))
    end

    def test_directories_with_empty_string
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        },
      )

      assert_equal(File.expand_path("."), agent_def.directory)
    end

    def test_to_h_with_empty_delegates_to
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          delegates_to: [],
        },
      )

      hash = agent_def.to_h

      assert_empty(hash[:delegates_to])
    end

    def test_to_h_with_nil_base_url
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          base_url: nil,
        },
      )

      hash = agent_def.to_h

      refute(hash.key?(:base_url))
    end

    def test_parameters_with_various_types
      agent_def = Agent::Definition.new(
        :test_agent,
        {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
          parameters: {
            temperature: 0.8,
            max_tokens: 4000,
            top_p: 0.9,
            presence_penalty: 0.5,
            frequency_penalty: 0.3,
            reasoning: "medium",
          },
        },
      )

      hash = agent_def.to_h

      assert_in_delta(0.8, hash[:parameters][:temperature])
      assert_equal(4000, hash[:parameters][:max_tokens])
      assert_in_delta(0.9, hash[:parameters][:top_p])
    end
  end
end
