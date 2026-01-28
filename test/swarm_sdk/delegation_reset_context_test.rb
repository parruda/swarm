# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Tests for reset_context parameter in delegation tools
  class DelegationResetContextTest < Minitest::Test
    def setup
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure { |config| config.openai_api_key = "test-key-12345" }

      @test_scratchpad = Tools::Stores::ScratchpadStorage.new
      @clear_conversation_called = false
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure { |config| config.openai_api_key = @original_api_key }
    end

    # Test: reset_context parameter appears in tool schema
    def test_reset_context_parameter_in_tool_schema
      swarm = create_swarm_with_delegation

      frontend_agent = swarm.agent(:frontend)
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      assert(delegation_tool, "Should have WorkWithBackend delegation tool")

      # Get tool parameters
      parameters = delegation_tool.parameters

      # Verify reset_context parameter exists
      assert(parameters.key?(:reset_context), "reset_context parameter should exist")
      reset_context_param = parameters[:reset_context]

      assert_equal("boolean", reset_context_param.type)
      assert_match(/prompt too long/i, reset_context_param.description)
      assert_match(/4XX/i, reset_context_param.description)
      refute(reset_context_param.required, "reset_context should be optional")
    end

    # Test: reset_context: true clears conversation before delegation
    def test_reset_context_true_clears_conversation
      swarm = create_swarm_with_delegation

      # Access frontend agent to trigger initialization (creates delegation instance)
      frontend_agent = swarm.agent(:frontend)

      # Get the delegation instance (isolated mode creates "backend@frontend")
      backend_agent = swarm.delegation_instances["backend@frontend"]

      assert(backend_agent, "Should have delegation instance")

      # Track if clear_conversation was called
      clear_called = false
      backend_agent.define_singleton_method(:clear_conversation) do
        clear_called = true
      end

      # Mock ask method — clear_context: is handled inside ask's semaphore,
      # so the mock must call clear_conversation when clear_context is true
      backend_agent.define_singleton_method(:ask) do |_task, **options|
        clear_conversation if options[:clear_context]
        Struct.new(:content).new("Backend response")
      end

      # Get delegation tool
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Execute with reset_context: true
      result = delegation_tool.execute(message: "Build API", reset_context: true)

      assert(clear_called, "clear_conversation should be called when reset_context: true")
      assert_equal("Backend response", result)
    end

    # Test: reset_context: false preserves conversation (when preserve_context: true)
    def test_reset_context_false_preserves_conversation_with_preserve_context_true
      swarm = create_swarm_with_delegation

      # Access frontend agent to trigger initialization
      frontend_agent = swarm.agent(:frontend)

      # Get the delegation instance
      backend_agent = swarm.delegation_instances["backend@frontend"]

      assert(backend_agent, "Should have delegation instance")

      # Track if clear_conversation was called
      clear_called = false
      backend_agent.define_singleton_method(:clear_conversation) do
        clear_called = true
      end

      # Mock ask method — clear_context: is handled inside ask's semaphore
      backend_agent.define_singleton_method(:ask) do |_task, **options|
        clear_conversation if options[:clear_context]
        Struct.new(:content).new("Backend response")
      end

      # Get delegation tool
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Verify preserve_context is true by default
      assert(delegation_tool.preserve_context, "preserve_context should be true by default")

      # Execute with reset_context: false (explicit)
      result = delegation_tool.execute(message: "Build API", reset_context: false)

      refute(clear_called, "clear_conversation should NOT be called when reset_context: false and preserve_context: true")
      assert_equal("Backend response", result)
    end

    # Test: reset_context: false still clears when preserve_context: false
    def test_reset_context_false_clears_when_preserve_context_false
      swarm = create_swarm_with_delegation(preserve_context: false)

      # Access frontend agent to trigger initialization
      frontend_agent = swarm.agent(:frontend)

      # Get the delegation instance
      backend_agent = swarm.delegation_instances["backend@frontend"]

      assert(backend_agent, "Should have delegation instance")

      # Track if clear_conversation was called
      clear_called = false
      backend_agent.define_singleton_method(:clear_conversation) do
        clear_called = true
      end

      # Mock ask method — clear_context: is handled inside ask's semaphore
      backend_agent.define_singleton_method(:ask) do |_task, **options|
        clear_conversation if options[:clear_context]
        Struct.new(:content).new("Backend response")
      end

      # Get delegation tool
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Verify preserve_context is false
      refute(delegation_tool.preserve_context, "preserve_context should be false")

      # Execute with reset_context: false
      result = delegation_tool.execute(message: "Build API", reset_context: false)

      assert(clear_called, "clear_conversation SHOULD be called when preserve_context: false, even if reset_context: false")
      assert_equal("Backend response", result)
    end

    # Test: reset_context: true works even when preserve_context: false (no conflict)
    def test_reset_context_true_works_with_preserve_context_false
      swarm = create_swarm_with_delegation(preserve_context: false)

      # Access frontend agent to trigger initialization
      frontend_agent = swarm.agent(:frontend)

      # Get the delegation instance
      backend_agent = swarm.delegation_instances["backend@frontend"]

      assert(backend_agent, "Should have delegation instance")

      # Track if clear_conversation was called
      clear_called = false
      backend_agent.define_singleton_method(:clear_conversation) do
        clear_called = true
      end

      # Mock ask method — clear_context: is handled inside ask's semaphore
      backend_agent.define_singleton_method(:ask) do |_task, **options|
        clear_conversation if options[:clear_context]
        Struct.new(:content).new("Backend response")
      end

      # Get delegation tool
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Execute with reset_context: true
      result = delegation_tool.execute(message: "Build API", reset_context: true)

      assert(clear_called, "clear_conversation should be called when reset_context: true")
      assert_equal("Backend response", result)
    end

    # Test: omitting reset_context parameter defaults to false (backward compatibility)
    def test_omitting_reset_context_defaults_to_false
      swarm = create_swarm_with_delegation

      # Access frontend agent to trigger initialization
      frontend_agent = swarm.agent(:frontend)

      # Get the delegation instance
      backend_agent = swarm.delegation_instances["backend@frontend"]

      assert(backend_agent, "Should have delegation instance")

      # Track if clear_conversation was called
      clear_called = false
      backend_agent.define_singleton_method(:clear_conversation) do
        clear_called = true
      end

      # Mock ask method — clear_context: is handled inside ask's semaphore
      backend_agent.define_singleton_method(:ask) do |_task, **options|
        clear_conversation if options[:clear_context]
        Struct.new(:content).new("Backend response")
      end

      # Get delegation tool
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Execute WITHOUT reset_context parameter (backward compatibility)
      result = delegation_tool.execute(message: "Build API")

      refute(clear_called, "clear_conversation should NOT be called when reset_context is omitted (defaults to false)")
      assert_equal("Backend response", result)
    end

    # Test: reset_context clears conversation multiple times in sequence
    def test_reset_context_clears_conversation_multiple_times
      swarm = create_swarm_with_delegation

      # Access frontend agent to trigger initialization
      frontend_agent = swarm.agent(:frontend)

      # Get the delegation instance
      backend_agent = swarm.delegation_instances["backend@frontend"]

      assert(backend_agent, "Should have delegation instance")

      # Track how many times clear_conversation was called
      clear_count = 0
      backend_agent.define_singleton_method(:clear_conversation) do
        clear_count += 1
      end

      # Mock ask method — clear_context: is handled inside ask's semaphore
      backend_agent.define_singleton_method(:ask) do |_task, **options|
        clear_conversation if options[:clear_context]
        Struct.new(:content).new("Backend response #{clear_count}")
      end

      # Get delegation tool
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Execute multiple times with reset_context: true
      result1 = delegation_tool.execute(message: "First task", reset_context: true)
      result2 = delegation_tool.execute(message: "Second task", reset_context: true)
      result3 = delegation_tool.execute(message: "Third task", reset_context: true)

      assert_equal(3, clear_count, "clear_conversation should be called 3 times")
      assert_equal("Backend response 1", result1)
      assert_equal("Backend response 2", result2)
      assert_equal("Backend response 3", result3)
    end

    # Test: reset_context parameter appears in tool description
    def test_reset_context_mentioned_in_description
      swarm = create_swarm_with_delegation

      frontend_agent = swarm.agent(:frontend)
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Get tool parameters
      parameters = delegation_tool.parameters

      # Verify reset_context is documented
      reset_context_param = parameters[:reset_context]
      description = reset_context_param.description

      assert_match(/reset/i, description, "Description should mention 'reset'")
      assert_match(/conversation|context|history/i, description, "Description should mention conversation/context/history")
      assert_match(/prompt too long/i, description, "Description should mention 'prompt too long' errors")
      assert_match(/4XX/i, description, "Description should mention '4XX' errors")
    end

    private

    def create_swarm_with_delegation(preserve_context: true)
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      delegation_config = if preserve_context
        [:backend]
      else
        [{ agent: :backend, preserve_context: false }]
      end

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: delegation_config,
        directory: ".",
      ))

      swarm.lead = :frontend

      # Force lazy delegate initialization for tests that need to access delegation instances
      swarm.initialize_lazy_delegates!

      swarm
    end

    def create_agent(name:, **config)
      config[:description] ||= "Test agent #{name}"
      config[:model] ||= "gpt-5"
      config[:system_prompt] ||= "Test"
      config[:directory] ||= "."
      config[:streaming] = false unless config.key?(:streaming)

      Agent::Definition.new(name, config)
    end
  end
end
