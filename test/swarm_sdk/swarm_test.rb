# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "yaml"

module SwarmSDK
  class SwarmTest < Minitest::Test
    def setup
      # Set fake API key to avoid RubyLLM configuration errors
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      # Also configure RubyLLM directly to avoid caching issues
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
      end

      # Create test scratchpad to avoid writing to filesystem
      @test_scratchpad = create_test_scratchpad
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      # Reset RubyLLM configuration
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
      end

      # Clean up test scratchpad files
      cleanup_test_scratchpads
    end

    def test_initialization_with_defaults
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      assert_equal("Test Swarm", swarm.name)
      assert_nil(swarm.lead_agent)
    end

    def test_add_agent_with_required_fields
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      result = swarm.add_agent(create_agent(
        name: :test_agent,
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "You are a test agent",
        directory: ".",
      ))

      assert_equal(swarm, result) # Returns self for chaining
      assert_includes(swarm.agent_names, :test_agent)
    end

    def test_add_agent_with_all_fields
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :full_agent,
        description: "Full agent",
        model: "claude-sonnet-4",
        system_prompt: "You are full",
        tools: [:Read, :Edit],
        delegates_to: [:other],
        directory: ".",
        base_url: "https://api.anthropic.com",
        mcp_servers: [{ type: :stdio }],
        parameters: {
          temperature: 0.7,
          max_tokens: 4000,
          reasoning: "high",
        },
        max_concurrent_tools: 15,
      ))

      assert_includes(swarm.agent_names, :full_agent)
    end

    def test_add_agent_converts_name_to_symbol
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: "string_name",
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      assert_includes(swarm.agent_names, :string_name)
    end

    def test_add_duplicate_agent_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :duplicate,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      error = assert_raises(ConfigurationError) do
        swarm.add_agent(create_agent(
          name: :duplicate,
          description: "Test",
          model: "gpt-5",
          system_prompt: "Test",
          directory: ".",
        ))
      end

      assert_match(/already exists/i, error.message)
    end

    def test_add_agent_uses_default_directories
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
      ))

      agent_def = swarm.agent_definition(:test)

      assert_equal(File.expand_path("."), agent_def.directory)
    end

    def test_set_lead_agent
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      assert_equal(:lead, swarm.lead_agent)
    end

    def test_set_lead_converts_to_symbol
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = "lead"

      assert_equal(:lead, swarm.lead_agent)
    end

    def test_set_nonexistent_lead_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      error = assert_raises(ConfigurationError) do
        swarm.lead = :nonexistent
      end

      assert_match(/cannot set lead.*not found/i, error.message)
    end

    def test_agent_names_returns_all_names
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :agent1,
        description: "A1",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))
      swarm.add_agent(create_agent(
        name: :agent2,
        description: "A2",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))
      swarm.add_agent(create_agent(
        name: :agent3,
        description: "A3",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      names = swarm.agent_names

      assert_equal(3, names.length)
      assert_includes(names, :agent1)
      assert_includes(names, :agent2)
      assert_includes(names, :agent3)
    end

    def test_load_from_yaml
      config = valid_yaml_config

      with_yaml_file(config) do |path|
        swarm = SwarmSDK.load_file(path)

        assert_instance_of(Swarm, swarm)
        assert_equal("Test Swarm", swarm.name)
        assert_equal(:lead, swarm.lead_agent)
        assert_equal(2, swarm.agent_names.length)
      end
    end

    def test_execute_without_lead_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      error = assert_raises(ConfigurationError) do
        swarm.execute("Do something")
      end

      assert_match(/no lead agent/i, error.message)
    end

    def test_default_constants
      assert_equal(50, Defaults::Concurrency::GLOBAL_LIMIT)
      assert_equal(10, Defaults::Concurrency::LOCAL_LIMIT)
    end

    def test_chaining_add_agent_and_set_lead
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)
        .add_agent(create_agent(
          name: :lead,
          description: "Lead",
          model: "gpt-5",
          system_prompt: "Test",
          directory: ".",
        ))
        .add_agent(create_agent(
          name: :backend,
          description: "Backend",
          model: "gpt-5",
          system_prompt: "Test",
          directory: ".",
        ))

      swarm.lead = :lead

      assert_equal(2, swarm.agent_names.length)
      assert_equal(:lead, swarm.lead_agent)
    end

    def test_agent_uses_default_timeout
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :agent1,
        description: "Agent 1",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      agent_def = swarm.agent_definition(:agent1)

      assert_equal(300, agent_def.timeout) # 5 minutes default
    end

    def test_agent_can_override_timeout
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :agent1,
        description: "Agent 1",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        timeout: 600, # 10 minutes for reasoning models
      ))

      agent_def = swarm.agent_definition(:agent1)

      assert_equal(600, agent_def.timeout)
    end

    def test_agent_method_with_string_converts_to_symbol
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test_agent,
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.agent(swarm.agent_names.first)

      agent = swarm.agent("test_agent")

      assert_instance_of(Agent::Chat, agent)
    end

    def test_agent_method_with_nonexistent_agent_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      error = assert_raises(AgentNotFoundError) do
        swarm.agent(:nonexistent)
      end

      assert_match(/agent.*not found/i, error.message)
    end

    def test_execute_returns_result_instance
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      # Mock HTTP response from LLM API
      stub_llm_request(mock_llm_response(content: "Test response"))

      result = swarm.execute("test prompt")

      assert_instance_of(Result, result)
      assert_equal("Test response", result.content)
      assert_equal("lead", result.agent)
      assert_predicate(result, :success?)
    end

    def test_execute_with_error_returns_failed_result
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      # Mock the lead agent to raise an error
      swarm.agent(swarm.agent_names.first)
      lead_agent = swarm.agent(:lead)

      lead_agent.define_singleton_method(:ask) do |_prompt|
        raise StandardError, "Test error"
      end

      result = swarm.execute("test prompt")

      assert_instance_of(Result, result)
      refute_predicate(result, :success?)
      assert_predicate(result, :failure?)
      assert_instance_of(StandardError, result.error)
      assert_equal("Test error", result.error.message)
    end

    def test_execute_with_type_error_returns_llm_error_for_proxy
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        provider: "openai",
        base_url: "https://custom.proxy",
        directory: ".",
      ))

      swarm.lead = :lead

      # Mock the lead agent to raise a TypeError with dig method error
      swarm.agent(swarm.agent_names.first)
      lead_agent = swarm.agent(:lead)

      lead_agent.define_singleton_method(:ask) do |_prompt|
        raise TypeError, "String does not have #dig method"
      end

      result = swarm.execute("test prompt")

      assert_instance_of(Result, result)
      refute_predicate(result, :success?)
      assert_instance_of(LLMError, result.error)
      assert_match(/proxy.*unreachable/i, result.error.message)
      assert_match(/custom\.proxy/i, result.error.message)
    end

    def test_execute_with_streaming_logs
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      # Mock HTTP response from LLM API
      stub_llm_request(mock_llm_response(content: "Test response"))

      logs = []
      result = swarm.execute("test prompt") do |log_entry|
        logs << log_entry
      end

      assert_instance_of(Result, result)
      assert_predicate(result, :success?)
    end

    def test_register_agent_tools_adds_delegation_tools
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      # Initialize agents
      swarm.agent(swarm.agent_names.first)

      lead_agent = swarm.agent(:lead)

      # Verify backend tool was registered
      assert(lead_agent.has_tool?(:WorkWithBackend), "Expected backend tool to be registered")
    end

    def test_register_agent_tools_with_unknown_agent_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        delegates_to: [:nonexistent],
        directory: ".",
      ))

      swarm.lead = :lead

      error = assert_raises(ConfigurationError) do
        swarm.agent(swarm.agent_names.first)
      end

      assert_match(/unknown agent/i, error.message)
    end

    def test_execute_with_agent_delegation
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      # Initialize agents to create delegation instances
      swarm.agent(swarm.agent_names.first)

      # Backend is only used as a delegate, so access the delegation instance
      backend_agent = swarm.delegation_instances["backend@lead"]
      backend_mock_response = Struct.new(:content).new("Backend response")
      backend_agent.define_singleton_method(:ask) do |_task|
        backend_mock_response
      end

      lead_agent = swarm.agent(:lead)
      lead_mock_response = Struct.new(:content).new("Lead final response")
      lead_agent.define_singleton_method(:ask) do |_prompt|
        lead_mock_response
      end

      result = swarm.execute("test task")

      assert_predicate(result, :success?)
      assert_equal("Lead final response", result.content)
    end

    def test_initialize_agents_sets_system_prompt
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :agent1,
        description: "Agent 1",
        model: "gpt-5",
        system_prompt: "Custom system prompt",
        directory: ".",
      ))

      swarm.agent(swarm.agent_names.first)

      # We can't easily test this without exposing internal RubyLLM state
      # but we can verify the agent was created
      agent = swarm.agent(:agent1)

      assert_instance_of(Agent::Chat, agent)
    end

    def test_initialize_agents_configures_parameters
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :agent1,
        description: "Agent 1",
        model: "gpt-5",
        system_prompt: "Test",
        parameters: {
          temperature: 0.7,
          max_tokens: 2000,
        },
        directory: ".",
      ))

      swarm.agent(swarm.agent_names.first)

      agent = swarm.agent(:agent1)

      assert_instance_of(Agent::Chat, agent)
    end

    def test_execute_with_configuration_error_raises
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      # No lead agent set

      error = assert_raises(ConfigurationError) do
        swarm.execute("test")
      end

      assert_match(/no lead agent/i, error.message)
    end

    def test_execute_duration_is_measured
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      swarm.agent(swarm.agent_names.first)
      lead_agent = swarm.agent(:lead)

      mock_response = Struct.new(:content).new("Test response")
      lead_agent.define_singleton_method(:ask) do |_prompt|
        sleep(0.05) # Simulate some work
        mock_response
      end

      result = swarm.execute("test")

      assert_operator(result.duration, :>, 0, "Expected duration to be positive")
      assert_operator(result.duration, :>=, 0.05, "Expected duration to be at least 0.05 seconds")
    end

    def test_execute_with_type_error_without_base_url
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.lead = :lead

      # Mock the lead agent to raise a TypeError that doesn't match the special case
      swarm.agent(swarm.agent_names.first)
      lead_agent = swarm.agent(:lead)

      lead_agent.define_singleton_method(:ask) do |_prompt|
        raise TypeError, "Some other type error"
      end

      result = swarm.execute("test prompt")

      assert_instance_of(Result, result)
      refute_predicate(result, :success?)
      assert_instance_of(TypeError, result.error)
    end

    def test_execute_with_nil_lead_agent_in_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      # Add agent but don't set lead
      swarm.add_agent(create_agent(
        name: :agent1,
        description: "Agent 1",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      # Try to execute without lead (should raise ConfigurationError)
      error = assert_raises(ConfigurationError) do
        swarm.execute("test")
      end

      assert_includes(error.message, "No lead agent")
    end

    def test_agent_with_no_system_prompt
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: nil,
        directory: ".",
      ))

      swarm.agent(swarm.agent_names.first)

      # Should create agent successfully
      assert_instance_of(Agent::Chat, swarm.agent(:test))
    end

    def test_agent_with_no_parameters
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        parameters: nil,
      ))

      swarm.agent(swarm.agent_names.first)

      assert_instance_of(Agent::Chat, swarm.agent(:test))
    end

    def test_agent_with_empty_parameters
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        parameters: {},
      ))

      swarm.agent(swarm.agent_names.first)

      assert_instance_of(Agent::Chat, swarm.agent(:test))
    end

    def test_set_bypass_permissions
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.agent_definition(:test).bypass_permissions = true

      agent_def = swarm.agent_definition(:test)

      assert(agent_def.bypass_permissions)
    end

    def test_set_bypass_permissions_with_string_name
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      swarm.agent_definition("test").bypass_permissions = false

      agent_def = swarm.agent_definition(:test)

      refute(agent_def.bypass_permissions)
    end

    def test_set_bypass_permissions_for_nonexistent_agent_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      error = assert_raises(AgentNotFoundError) do
        swarm.agent_definition(:nonexistent).bypass_permissions = true
      end

      assert_includes(error.message, "not found")
    end

    def test_agent_with_assume_model_exists_false
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      # Without base_url, assume_model_exists should default to false
      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        assume_model_exists: false,
      ))

      swarm.agent(swarm.agent_names.first)

      assert_instance_of(Agent::Chat, swarm.agent(:test))
    end

    def test_agent_with_assume_model_exists_explicit_with_base_url
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "custom-model",
        provider: "openai",
        base_url: "https://custom.api",
        system_prompt: "Test",
        directory: ".",
        assume_model_exists: true, # Explicitly set
      ))

      swarm.agent(swarm.agent_names.first)

      assert_instance_of(Agent::Chat, swarm.agent(:test))
    end

    def test_initialize_agents_without_logstream_emitter
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :agent1,
        description: "Agent 1",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
      ))

      # Ensure LogStream emitter is nil
      LogStream.emitter = nil

      # Access agent to trigger initialization
      agent = swarm.agent(:agent1)

      # Should create agents successfully without setting up logging
      assert_instance_of(Agent::Chat, agent)
    end

    def test_agent_names_returns_all_added_agents
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(name: :agent1, description: "A1", model: "gpt-5", system_prompt: "Test", directory: "."))
      swarm.add_agent(create_agent(name: :agent2, description: "A2", model: "gpt-5", system_prompt: "Test", directory: "."))
      swarm.add_agent(create_agent(name: :agent3, description: "A3", model: "gpt-5", system_prompt: "Test", directory: "."))

      names = swarm.agent_names

      assert_equal([:agent1, :agent2, :agent3], names.sort)
    end

    def test_agent_with_inline_tool_permissions
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      # Using inline permissions format: { Write: { allowed_paths: [...] } }
      swarm.add_agent(create_agent(
        name: :restricted,
        description: "Restricted agent",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        tools: [
          { Write: { allowed_paths: ["tmp/**/*"] } },
        ],
      ))

      # Access agent to trigger tool initialization
      agent = swarm.agent(:restricted)

      # Agent should have Write tool with permissions
      assert(agent.has_tool?(:Write))
    end

    def test_load_from_yaml_class_method
      config = valid_yaml_config

      with_yaml_file(config) do |path|
        swarm = SwarmSDK.load_file(path)

        assert_instance_of(Swarm, swarm)
        assert_equal("Test Swarm", swarm.name)
        assert_includes(swarm.agent_names, :lead)
        assert_includes(swarm.agent_names, :backend)
      end
    end

    def test_agent_with_string_tool_names
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        tools: ["Read", "Write"], # String names instead of symbols
      ))

      agent = swarm.agent(:test)

      # Should convert strings to symbols
      assert(agent.has_tool?(:Read))
      assert(agent.has_tool?(:Write))
    end

    def test_agent_with_mixed_tool_formats
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-5",
        system_prompt: "Test",
        directory: ".",
        tools: [
          :Read, # Symbol
          "Write", # String
          { Edit: { allowed_paths: ["**/*"] } }, # Inline permissions format
        ],
      ))

      agent = swarm.agent(:test)

      assert(agent.has_tool?(:Read))
      assert(agent.has_tool?(:Write))
      assert(agent.has_tool?(:Edit))
    end

    # Tests for scratchpad mode validation
    def test_swarm_scratchpad_enabled_mode
      swarm = SwarmSDK.build do
        name("Scratchpad Test")
        scratchpad(:enabled)

        agent(:dev) do
          description("Developer")
          model("gpt-4o-mini")
          system_prompt("You code")
          coding_agent(false)
        end

        lead(:dev)
      end

      assert_predicate(swarm, :scratchpad_enabled?)
      refute_nil(swarm.scratchpad_storage)
    end

    def test_swarm_scratchpad_disabled_mode
      swarm = SwarmSDK.build do
        name("Scratchpad Disabled Test")
        scratchpad(:disabled)

        agent(:dev) do
          description("Developer")
          model("gpt-4o-mini")
          system_prompt("You code")
          coding_agent(false)
        end

        lead(:dev)
      end

      refute_predicate(swarm, :scratchpad_enabled?)
      assert_nil(swarm.scratchpad_storage)
    end

    def test_swarm_rejects_per_node_mode
      error = assert_raises(ArgumentError) do
        SwarmSDK.build do
          name("Invalid")
          scratchpad(:per_node) # Should fail for regular Swarm

          agent(:dev) do
            description("Developer")
            model("gpt-4o-mini")
            system_prompt("You code")
            coding_agent(false)
          end

          lead(:dev)
        end
      end

      assert_match(/:per_node is only valid for Workflow/, error.message)
      assert_match(/use :enabled or :disabled/, error.message)
    end

    def test_swarm_scratchpad_default_is_disabled
      swarm = SwarmSDK.build do
        name("Default Test")
        # Don't set scratchpad - should default to :disabled

        agent(:dev) do
          description("Developer")
          model("gpt-4o-mini")
          system_prompt("You code")
          coding_agent(false)
        end

        lead(:dev)
      end

      refute_predicate(swarm, :scratchpad_enabled?)
      assert_nil(swarm.scratchpad_storage)
    end

    def test_swarm_scratchpad_yaml_string_conversion
      yaml = <<~YAML
        version: 2
        swarm:
          name: String Test
          scratchpad: disabled

          agents:
            dev:
              description: Developer
              model: gpt-4o-mini
              system_prompt: You code

          lead: dev
      YAML

      swarm = SwarmSDK.load(yaml, base_dir: ".")

      refute_predicate(swarm, :scratchpad_enabled?)
    end

    private

    def valid_yaml_config
      {
        "version" => 2,
        "swarm" => {
          "name" => "Test Swarm",
          "lead" => "lead",
          "agents" => {
            "lead" => {
              "description" => "Lead agent",
              "system_prompt" => "You are the lead",
              "delegates_to" => ["backend"],
              "directory" => ".",
            },
            "backend" => {
              "description" => "Backend agent",
              "system_prompt" => "You build APIs",
              "delegates_to" => [],
              "directory" => ".",
            },
          },
        },
      }
    end

    def with_yaml_file(config)
      Tempfile.create(["swarm-test", ".yml"]) do |file|
        file.write(YAML.dump(config))
        file.flush
        yield file.path
      end
    end
  end
end
