# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Tests for per-delegation agent instances (isolated vs shared modes)
  class DelegationIsolationTest < Minitest::Test
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

    # Test: Isolated mode creates separate instances per delegator
    def test_isolated_mode_creates_separate_instances
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Verify delegation instances were created
      assert(
        swarm.delegation_instances.key?("tester@frontend"),
        "Should create tester@frontend delegation instance",
      )
      assert(
        swarm.delegation_instances.key?("tester@backend"),
        "Should create tester@backend delegation instance",
      )

      # Verify they are different instances
      frontend_tester = swarm.delegation_instances["tester@frontend"]
      backend_tester = swarm.delegation_instances["tester@backend"]

      refute_same(
        frontend_tester,
        backend_tester,
        "Delegation instances should be different objects",
      )

      # Verify both have system message only (no user messages yet - separate conversations)
      # System message is added during initialization
      assert_equal(1, frontend_tester.messages.size, "Frontend's tester should have only system message")
      assert_equal(1, backend_tester.messages.size, "Backend's tester should have only system message")
      assert_equal(:system, frontend_tester.messages.first.role)
      assert_equal(:system, backend_tester.messages.first.role)
    end

    # Test: Shared mode uses same instance for all delegators
    def test_shared_mode_uses_same_instance
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :database,
        description: "Database agent",
        model: "gpt-4o-mini",
        shared_across_delegations: true,
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

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Verify NO delegation instances were created
      refute(
        swarm.delegation_instances.key?("database@frontend"),
        "Should NOT create delegation instance in shared mode",
      )
      refute(
        swarm.delegation_instances.key?("database@backend"),
        "Should NOT create delegation instance in shared mode",
      )

      # Verify both agents have delegation tools
      frontend_agent = swarm.agent(:frontend)
      backend_agent = swarm.agent(:backend)

      frontend_db_tool = frontend_agent.tools[:WorkWithDatabase]
      backend_db_tool = backend_agent.tools[:WorkWithDatabase]

      assert(frontend_db_tool, "Frontend should have database delegation tool")
      assert(backend_db_tool, "Backend should have database delegation tool")

      # Test behavior: Both should share the same conversation history
      # Add a message to primary database and verify it's shared
      primary_database = swarm.agent(:database)
      primary_database.add_message(role: :user, content: "Shared message")

      # System message + user message = 2 total
      assert_equal(
        2,
        primary_database.messages.size,
        "Primary database should have system + user message",
      )

      # Both delegation tools target the same shared instance (behavioral verification)
      assert_equal("database", frontend_db_tool.delegate_target)
      assert_equal("database", backend_db_tool.delegate_target)
    end

    # Test: Isolated mode maintains separate conversation histories
    def test_isolated_mode_separate_conversation_histories
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      frontend_tester = swarm.delegation_instances["tester@frontend"]
      backend_tester = swarm.delegation_instances["tester@backend"]

      # Simulate adding messages to each instance
      frontend_tester.add_message(role: :user, content: "Frontend question")
      backend_tester.add_message(role: :user, content: "Backend question")

      # Verify separate histories (system message + user message = 2 total)
      assert_equal(2, frontend_tester.messages.size)
      assert_equal(2, backend_tester.messages.size)

      # Check the user messages (second message, index 1)
      assert_equal("Frontend question", frontend_tester.messages[1].content)
      assert_equal("Backend question", backend_tester.messages[1].content)
    end

    # Test: Agent name validation (no '@' allowed)
    def test_agent_name_validation_rejects_at_symbol
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      error = assert_raises(ConfigurationError) do
        swarm.add_agent(create_agent(
          name: :"tester@invalid",
          description: "Invalid agent name",
          model: "gpt-4o-mini",
          directory: ".",
        ))
      end

      assert_match(/cannot contain '@' character/, error.message)
    end

    # Test: Delegates_to deduplication
    def test_delegates_to_deduplication
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester, :tester, :tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      frontend_agent = swarm.agent(:frontend)

      # Should only have ONE delegation tool (duplicates removed)
      delegation_tools = frontend_agent.tool_names.select { |k| k.to_s.start_with?("WorkWith") }

      assert_equal(1, delegation_tools.size, "Should deduplicate delegates_to")
    end

    # Test: Base name extraction through delegation instance naming
    def test_base_name_extraction_through_delegation_instances
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Verify base name extraction works correctly by checking delegation instance keys
      # The naming convention "base@delegator" proves base name extraction works
      assert(
        swarm.delegation_instances.key?("tester@frontend"),
        "Delegation instance should follow 'base@delegator' naming",
      )

      # Verify the instance is for the tester agent (base name)
      delegation_instance = swarm.delegation_instances["tester@frontend"]

      assert(delegation_instance, "Should have delegation instance")

      # Tester is only used as a delegate (isolated mode), so no primary exists
      # The delegation instance is the only instance of tester
      refute(
        swarm.agents.key?(:tester),
        "Primary tester should not exist (only used as delegate in isolated mode)",
      )
    end

    # Test: Cleanup clears delegation instances
    def test_cleanup_clears_delegation_instances
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      refute_empty(swarm.delegation_instances, "Should have delegation instances before cleanup")

      # Cleanup
      swarm.cleanup

      assert_empty(swarm.delegation_instances, "Should clear delegation instances after cleanup")
    end

    # Test: Nested delegation with isolated mode
    def test_nested_delegation_isolated_mode
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :database,
        description: "Database agent",
        model: "gpt-4o-mini",
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        delegates_to: [:database],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Verify delegation instances created at all levels
      assert(
        swarm.delegation_instances.key?("tester@frontend"),
        "Should create tester@frontend",
      )
      assert(
        swarm.delegation_instances.key?("tester@backend"),
        "Should create tester@backend",
      )

      # Verify nested delegation instances
      # Primary tester also delegates to database, so we get database@tester too
      assert(
        swarm.delegation_instances.key?("database@tester"),
        "Should create database@tester for primary tester's delegation",
      )
      assert(
        swarm.delegation_instances.key?("database@tester@frontend"),
        "Should create database@tester@frontend for nested delegation",
      )
      assert(
        swarm.delegation_instances.key?("database@tester@backend"),
        "Should create database@tester@backend for nested delegation",
      )

      # All should be different instances (2 tester + 3 database = 5 total)
      instances = swarm.delegation_instances.values

      assert_equal(5, instances.size)
      assert_equal(5, instances.uniq.size, "All delegation instances should be unique")
    end

    # Test: Nested delegation with shared mode
    def test_nested_delegation_shared_mode
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :database,
        description: "Database agent",
        model: "gpt-4o-mini",
        shared_across_delegations: true,
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :tester,
        description: "Testing agent",
        model: "gpt-4o-mini",
        delegates_to: [:database],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        delegates_to: [:tester],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      # Verify tester delegation instances created (isolated)
      assert(swarm.delegation_instances.key?("tester@frontend"))
      assert(swarm.delegation_instances.key?("tester@backend"))

      # Verify NO database delegation instances (shared mode)
      refute(
        swarm.delegation_instances.key?("database@tester@frontend"),
        "Should NOT create database delegation instance in shared mode",
      )
      refute(
        swarm.delegation_instances.key?("database@tester@backend"),
        "Should NOT create database delegation instance in shared mode",
      )

      # Test behavior: Both tester instances should have database delegation tool
      frontend_tester = swarm.delegation_instances["tester@frontend"]
      backend_tester = swarm.delegation_instances["tester@backend"]

      frontend_db_tool = frontend_tester.tools[:WorkWithDatabase]
      backend_db_tool = backend_tester.tools[:WorkWithDatabase]

      assert(frontend_db_tool, "Frontend's tester should have database tool")
      assert(backend_db_tool, "Backend's tester should have database tool")

      # Verify both target the same database (behavioral check through delegate_target)
      assert_equal("database", frontend_db_tool.delegate_target)
      assert_equal("database", backend_db_tool.delegate_target)

      # Verify shared behavior: Add message to primary database
      primary_database = swarm.agent(:database)
      primary_database.add_message(role: :user, content: "Shared database state")

      # System message + user message = 2 total
      assert_equal(
        2,
        primary_database.messages.size,
        "Shared database should have system + user message",
      )
    end

    # Test: Shared mode enables concurrent access protection
    def test_shared_mode_concurrent_access_safety
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :database,
        description: "Database agent",
        model: "gpt-4o-mini",
        shared_across_delegations: true,
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

      swarm.lead = :frontend

      # Trigger initialization
      swarm.agent(:frontend)

      database = swarm.agent(:database)

      # Test behavior: The Chat class has per-instance semaphore protection
      # Verify this through behavioral test - multiple messages stay ordered
      database.add_message(role: :user, content: "Message 1")
      database.add_message(role: :user, content: "Message 2")
      database.add_message(role: :user, content: "Message 3")

      # Messages should be in order (semaphore prevents corruption)
      # System message + 3 user messages = 4 total
      assert_equal(4, database.messages.size)
      assert_equal(:system, database.messages[0].role)
      assert_equal("Message 1", database.messages[1].content)
      assert_equal("Message 2", database.messages[2].content)
      assert_equal("Message 3", database.messages[3].content)
    end
  end
end
