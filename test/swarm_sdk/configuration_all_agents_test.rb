# frozen_string_literal: true

require "test_helper"
require "tempfile"

module SwarmSDK
  class ConfigurationAllAgentsTest < Minitest::Test
    def setup
      # Set fake API keys to avoid RubyLLM configuration errors
      @original_anthropic_key = ENV["ANTHROPIC_API_KEY"]
      @original_openai_key = ENV["OPENAI_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "test-key-12345"
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure do |config|
        config.anthropic_api_key = "test-key-12345"
        config.openai_api_key = "test-key-12345"
      end
    end

    def teardown
      # Restore original API keys
      if @original_anthropic_key
        ENV["ANTHROPIC_API_KEY"] = @original_anthropic_key
      else
        ENV.delete("ANTHROPIC_API_KEY")
      end

      if @original_openai_key
        ENV["OPENAI_API_KEY"] = @original_openai_key
      else
        ENV.delete("OPENAI_API_KEY")
      end
    end

    def test_all_agents_with_common_tools
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            tools:
              - Write
              - Edit
          agents:
            developer:
              description: "Developer"
              model: gpt-5
              system_prompt: "You are a developer"
              tools: [Bash]
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm

        agent = swarm.agent(:developer)

        # Should have: defaults + all_agents.tools + agent.tools
        assert(agent.has_tool?(:Read), "Should have default Read")
        assert(agent.has_tool?(:Grep), "Should have default Grep")
        assert(agent.has_tool?(:Write), "Should have all_agents Write")
        assert(agent.has_tool?(:Edit), "Should have all_agents Edit")
        assert(agent.has_tool?(:Bash), "Should have agent Bash")
      end
    end

    def test_all_agents_disable_default_tools
      # NOTE: disable_default_tools in all_agents is not fully implemented yet
      # This test verifies YAML parses correctly, but feature needs DSL implementation
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            disable_default_tools: true
            tools:
              - Write
          agents:
            developer:
              description: "Developer"
              model: gpt-5
              system_prompt: "You are a developer"
              tools: [Bash]
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm
        agent = swarm.agent(:developer)

        # Verify swarm builds successfully
        assert(agent, "Agent should be created")

        # Verify agent has custom tools
        assert(agent.has_tool?(:Write), "Should have all_agents Write")
        assert(agent.has_tool?(:Bash), "Should have agent Bash")
      end
    end

    def test_agent_overrides_all_agents_disable_default_tools
      # Test verifies YAML translation works for disable_default_tools
      # Feature behavior is tested in DSL tests (default_tools_test.rb)
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            tools: [Write]
          agents:
            developer:
              description: "Developer 1"
              model: gpt-5
              system_prompt: "You are a developer"
              tools: [Bash]
              disable_default_tools:  # Array form
                - Think
            minimal:
              description: "Developer 2"
              model: gpt-5
              system_prompt: "You are minimal"
              tools: [Edit]
              disable_default_tools: true  # Boolean form
      YAML

      with_temp_config(yaml_content) do |config_path|
        # Just verify YAML parses and builds successfully
        swarm = Configuration.load_file(config_path).to_swarm

        developer = swarm.agent(:developer)
        minimal = swarm.agent(:minimal)

        # Verify agents created with custom tools
        assert(developer, "Developer should be created")
        assert(minimal, "Minimal should be created")
        assert(developer.has_tool?(:Write), "Should have all_agents Write")
        assert(developer.has_tool?(:Bash), "Should have agent Bash")
        assert(minimal.has_tool?(:Write), "Should have all_agents Write")
        assert(minimal.has_tool?(:Edit), "Should have agent Edit")

        # Full disable_default_tools behavior tested in default_tools_test.rb
      end
    end

    def test_all_agents_permissions_applied_to_all
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            permissions:
              Read:
                allowed_paths: ["src/**/*"]
          agents:
            developer:
              description: "Developer"
              model: gpt-5
              system_prompt: "You are a developer"
              tools: [Write]
      YAML

      with_temp_config(yaml_content) do |config_path|
        config = Configuration.load_file(config_path)

        # Verify permissions were loaded into all_agents_config
        assert_equal(["src/**/*"], config.all_agents_config[:permissions][:Read][:allowed_paths])
      end
    end

    def test_all_agents_model_applied_to_all
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            model: gpt-5
            provider: openai
          agents:
            developer:
              description: "Developer"
              system_prompt: "You are a developer"
            override:
              description: "Override"
              system_prompt: "You override"
              model: claude-sonnet-4  # Override all_agents model
              provider: anthropic
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm

        developer_def = swarm.agent_definitions[:developer]
        override_def = swarm.agent_definitions[:override]

        # Developer should have all_agents model
        assert_equal("gpt-5", developer_def.model)

        # Override should have its own model
        assert_equal("claude-sonnet-4", override_def.model)
      end
    end

    def test_all_agents_tools_concatenated
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            tools:
              - Write
              - Edit
          agents:
            developer:
              description: "Developer"
              model: gpt-5
              system_prompt: "You are a developer"
              tools: [Bash, Glob]  # Should be concatenated
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm

        developer = swarm.agent(:developer)

        # Should have all_agents tools + agent tools + defaults
        assert(developer.has_tool?(:Write), "Should have all_agents Write")
        assert(developer.has_tool?(:Edit), "Should have all_agents Edit")
        assert(developer.has_tool?(:Bash), "Should have agent Bash")
        assert(developer.has_tool?(:Glob), "Should have agent Glob")
        assert(developer.has_tool?(:Read), "Should have default Read")
      end
    end

    def test_agent_overrides_scalar_fields_from_all_agents
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: inherits
          all_agents:
            model: gpt-5
            provider: openai
            timeout: 300
            directory: "."
            parameters:
              temperature: 0.7
              max_tokens: 1000
          agents:
            inherits:
              description: "Inherits all_agents settings"
              system_prompt: "You inherit"
            overrides:
              description: "Overrides all_agents settings"
              system_prompt: "You override"
              model: claude-sonnet-4     # Override model
              provider: anthropic         # Override provider
              timeout: 600                # Override timeout
              directory: "."          # Override directories (use same dir for testing)
              parameters:
                temperature: 0.9          # Override parameters
                max_tokens: 2000
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm

        inherits_def = swarm.agent_definitions[:inherits]
        overrides_def = swarm.agent_definitions[:overrides]

        # Inherits should have all_agents values
        assert_equal("gpt-5", inherits_def.model)
        assert_equal("openai", inherits_def.provider)
        assert_equal(300, inherits_def.timeout)
        assert_in_delta(0.7, inherits_def.parameters[:temperature])
        assert_equal(1000, inherits_def.parameters[:max_tokens])

        # Overrides should have agent-specific values
        assert_equal("claude-sonnet-4", overrides_def.model)
        assert_equal("anthropic", overrides_def.provider)
        assert_equal(600, overrides_def.timeout)
        assert_in_delta(0.9, overrides_def.parameters[:temperature])
        assert_equal(2000, overrides_def.parameters[:max_tokens])
      end
    end

    def test_permissions_apply_to_default_tools
      # Test verifies YAML permissions translation works
      # Full permissions behavior tested in permissions_test.rb
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: developer
          all_agents:
            permissions:
              Read:
                denied_paths: ["lib/**/*", "src/**/*"]
          agents:
            developer:
              description: "Developer"
              model: gpt-5
              system_prompt: "You are a developer"
              tools: [Write]
              directory: "."
      YAML

      with_temp_config(yaml_content) do |config_path|
        # Just verify swarm builds successfully with permissions config
        swarm = Configuration.load_file(config_path).to_swarm
        developer = swarm.agent(:developer)

        # Verify agent was created with Read tool
        assert(developer, "Agent should be created")
        assert(developer.has_tool?(:Read), "Should have default Read tool")

        # Permissions behavior (deny/allow) is comprehensively tested in permissions_test.rb
        # This YAML test just verifies the configuration translates without errors
      end
    end

    def test_all_agents_base_url_and_headers
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: agent1
          all_agents:
            provider: openai
            base_url: "http://proxy.example.com/v1"
            headers:
              X-Custom-Header: "shared-value"
              X-Common: "common"
          agents:
            agent1:
              description: "Agent 1 - inherits all"
              model: gpt-4
              system_prompt: "Agent 1"
            agent2:
              description: "Agent 2 - overrides base_url"
              model: gpt-4
              system_prompt: "Agent 2"
              base_url: "http://other-proxy.com/v1"
              headers:
                X-Common: "overridden"
                X-Agent: "agent-specific"
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm

        agent1_def = swarm.agent_definitions[:agent1]
        agent2_def = swarm.agent_definitions[:agent2]

        # Agent1 inherits base_url and headers
        assert_equal("http://proxy.example.com/v1", agent1_def.base_url)
        assert_equal("shared-value", agent1_def.headers["X-Custom-Header"])
        assert_equal("common", agent1_def.headers["X-Common"])

        # Agent2 overrides base_url, merges headers
        assert_equal("http://other-proxy.com/v1", agent2_def.base_url)
        assert_equal("shared-value", agent2_def.headers["X-Custom-Header"]) # Inherited
        assert_equal("overridden", agent2_def.headers["X-Common"]) # Overridden
        assert_equal("agent-specific", agent2_def.headers["X-Agent"]) # Agent-only
      end
    end

    def test_all_agents_coding_agent
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Test Swarm"
          lead: agent1
          all_agents:
            coding_agent: true
          agents:
            agent1:
              description: "Agent 1 - inherits coding_agent"
              model: gpt-4
              system_prompt: "Agent 1"
            agent2:
              description: "Agent 2 - overrides to false"
              model: gpt-4
              system_prompt: "Agent 2"
              coding_agent: false
      YAML

      with_temp_config(yaml_content) do |config_path|
        swarm = Configuration.load_file(config_path).to_swarm

        agent1_def = swarm.agent_definitions[:agent1]
        agent2_def = swarm.agent_definitions[:agent2]

        # Agent1 inherits coding_agent: true
        assert(agent1_def.coding_agent)

        # Agent2 overrides to false
        refute(agent2_def.coding_agent)
      end
    end

    def test_all_agents_agent_step_hook_dsl
      # Test that :agent_step hook is allowed in all_agents block using DSL
      # This is a valid agent-level event defined in Hooks::Registry::VALID_EVENTS
      #
      # Before fix: raises ArgumentError: Invalid all_agents hook: agent_step
      # After fix: builds swarm successfully
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        all_agents do
          hook(:agent_step) do |ctx|
            # This hook should be allowed
          end
        end

        agent(:agent1) do
          model("gpt-5")
          provider("openai")
          system_prompt("You are a test agent")
          description("Test Agent")
        end
      end

      # Verify swarm was built successfully
      assert(swarm, "Swarm should be created successfully")
      assert_equal(:agent1, swarm.lead_agent, "Lead agent should be set")
    end

    private

    def with_temp_config(content)
      file = Tempfile.new(["swarm_config", ".yml"])
      begin
        file.write(content)
        file.close
        yield file.path
      ensure
        file.unlink
      end
    end
  end
end
