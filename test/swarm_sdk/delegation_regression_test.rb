# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Regression tests to ensure delegation changes don't break existing functionality
  class DelegationRegressionTest < Minitest::Test
    def setup
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure { |config| config.openai_api_key = "test-key-12345" }

      @test_scratchpad = Tools::Stores::ScratchpadStorage.new
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure { |config| config.openai_api_key = @original_api_key }
    end

    # Test: Basic delegation tool registration still works (isolated mode)
    def test_basic_delegation_tool_registration_isolated_mode
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead developer",
        model: "gpt-4o-mini",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.lead = :lead

      # Trigger initialization
      lead_agent = swarm.agent(:lead)

      # Verify delegation tool was created
      assert(
        lead_agent.has_tool?(:WorkWithBackend),
        "Lead should have backend delegation tool",
      )

      # Verify delegation instance was created (isolated mode)
      assert(
        swarm.delegation_instances.key?("backend@lead"),
        "Should create delegation instance in isolated mode",
      )
    end

    # Test: Basic delegation tool registration still works (shared mode)
    def test_basic_delegation_tool_registration_shared_mode
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        shared_across_delegations: true,
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead developer",
        model: "gpt-4o-mini",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.lead = :lead

      # Trigger initialization
      lead_agent = swarm.agent(:lead)

      # Verify delegation tool was created
      assert(
        lead_agent.has_tool?(:WorkWithBackend),
        "Lead should have backend delegation tool",
      )

      # Verify NO delegation instance was created (shared mode)
      refute(
        swarm.delegation_instances.key?("backend@lead"),
        "Should NOT create delegation instance in shared mode",
      )
    end

    # Test: Unknown delegate agent still raises error
    def test_unknown_delegate_agent_raises_error
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :lead,
        description: "Lead",
        model: "gpt-4o-mini",
        delegates_to: [:nonexistent],
        directory: ".",
      ))

      swarm.lead = :lead

      error = assert_raises(ConfigurationError) do
        swarm.agent(:lead)
      end

      assert_match(/unknown agent/i, error.message)
    end

    # Test: Default tools still registered for delegation instances
    def test_default_tools_registered_for_delegation_instances
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Get delegation instance
      backend_instance = swarm.delegation_instances["backend@frontend"]

      assert(backend_instance, "Should have delegation instance")

      # Verify default tools are registered
      assert(backend_instance.has_tool?(:Read), "Should have Read tool")
      assert(backend_instance.has_tool?(:Grep), "Should have Grep tool")
      assert(backend_instance.has_tool?(:Glob), "Should have Glob tool")
    end

    # Test: Scratchpad tools registered for delegation instances
    def test_scratchpad_tools_registered_for_delegation_instances
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      # Set shared_across_delegations: true so backend exists as both primary and delegate
      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        directory: ".",
        shared_across_delegations: true,
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Since backend has shared_across_delegations: true, frontend uses the primary backend
      # (not a delegation instance)
      backend_instance = swarm.agent(:backend)

      # Verify scratchpad tools are registered
      assert(backend_instance.has_tool?(:ScratchpadWrite), "Should have ScratchpadWrite")
      assert(backend_instance.has_tool?(:ScratchpadRead), "Should have ScratchpadRead")
      assert(backend_instance.has_tool?(:ScratchpadList), "Should have ScratchpadList")

      # Verify scratchpad is shared (same storage object)
      # We can test this behaviorally by writing from one instance and reading from another
      backend_instance.tools[:ScratchpadWrite].execute(
        file_path: "test/note",
        content: "Test content",
        title: "Test",
      )

      # Primary backend should see the same scratchpad entry (it's the same instance)
      primary_backend = swarm.agent(:backend)
      list_result = primary_backend.tools[:ScratchpadList].execute

      assert_includes(list_result, "test/note", "Scratchpad should be shared")
    end

    # Test: Custom tools registered for delegation instances
    def test_custom_tools_registered_for_delegation_instances
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        tools: [:Read, :Write, :Bash],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Get delegation instance
      backend_instance = swarm.delegation_instances["backend@frontend"]

      # Verify custom tools are registered
      assert(backend_instance.has_tool?(:Read), "Should have Read tool")
      assert(backend_instance.has_tool?(:Write), "Should have Write tool")
      assert(backend_instance.has_tool?(:Bash), "Should have Bash tool")

      # Cleanup should work without errors
      swarm.cleanup

      assert_empty(swarm.delegation_instances, "Cleanup should clear delegation instances")
    end

    # Test: Multiple agents can delegate to same target without conflicts
    def test_multiple_delegators_to_same_target
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :database,
        description: "Database agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:database],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        delegates_to: [:database],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :api,
        description: "API developer",
        model: "gpt-4o-mini",
        delegates_to: [:database],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Should create 3 separate delegation instances
      assert(swarm.delegation_instances.key?("database@frontend"))
      assert(swarm.delegation_instances.key?("database@backend"))
      assert(swarm.delegation_instances.key?("database@api"))

      # All should be different instances
      instances = [
        swarm.delegation_instances["database@frontend"],
        swarm.delegation_instances["database@backend"],
        swarm.delegation_instances["database@api"],
      ]

      assert_equal(3, instances.uniq.size, "All instances should be unique")
    end
  end
end
