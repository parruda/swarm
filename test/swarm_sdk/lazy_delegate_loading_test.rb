# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Tests for lazy loading of delegation instances
  class LazyDelegateLoadingTest < Minitest::Test
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

    # Test: Isolated delegates are not created at swarm initialization
    def test_isolated_delegates_not_created_at_initialization
      swarm = create_swarm_with_delegation

      # Trigger agent initialization
      swarm.agent(:frontend)

      # Delegation instance should NOT exist yet (lazy loading)
      refute(
        swarm.delegation_instances.key?("backend@frontend"),
        "Delegation instance should not be created at initialization",
      )
    end

    # Test: Delegation tool has lazy? and initialized? methods
    def test_delegation_tool_has_lazy_status_methods
      swarm = create_swarm_with_delegation

      frontend_agent = swarm.agent(:frontend)
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Tool should be lazy (isolated mode)
      assert_predicate(delegation_tool, :lazy?, "Delegation tool should be lazy")
      refute_predicate(delegation_tool, :initialized?, "Delegation tool should not be initialized yet")
    end

    # Test: Delegation instance created on first delegation call
    def test_delegation_instance_created_on_first_call
      swarm = create_swarm_with_delegation

      frontend_agent = swarm.agent(:frontend)
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Mock the delegate's ask method to avoid actual LLM call
      delegation_tool.initialize_delegate!
      backend_instance = swarm.delegation_instances["backend@frontend"]

      backend_instance.define_singleton_method(:ask) do |_task, **_options|
        Struct.new(:content).new("Backend response")
      end

      # Execute delegation (should use already-initialized delegate)
      result = delegation_tool.execute(message: "Build API")

      assert_predicate(delegation_tool, :initialized?, "Delegation tool should be initialized after call")
      assert(
        swarm.delegation_instances.key?("backend@frontend"),
        "Delegation instance should exist after call",
      )
      assert_equal("Backend response", result)
    end

    # Test: initialize_lazy_delegates! forces initialization
    def test_initialize_lazy_delegates_forces_initialization
      swarm = create_swarm_with_delegation

      # Trigger agent initialization
      swarm.agent(:frontend)

      # Verify delegate is lazy before forcing initialization
      frontend_agent = swarm.agent(:frontend)
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      assert_predicate(delegation_tool, :lazy?)
      refute_predicate(delegation_tool, :initialized?)

      # Force initialization
      swarm.initialize_lazy_delegates!

      # Now it should be initialized
      assert_predicate(delegation_tool, :initialized?)
      assert(swarm.delegation_instances.key?("backend@frontend"))
    end

    # Test: Shared delegates are not lazy (use primary instance)
    def test_shared_delegates_not_lazy
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      swarm.add_agent(create_agent(
        name: :backend,
        description: "Backend developer",
        model: "gpt-4o-mini",
        shared_across_delegations: true,
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

      frontend_agent = swarm.agent(:frontend)
      delegation_tool = frontend_agent.tools[:WorkWithBackend]

      # Shared delegates should NOT be lazy
      refute_predicate(delegation_tool, :lazy?, "Shared delegates should not be lazy")
      assert_predicate(delegation_tool, :initialized?, "Shared delegates should be initialized immediately")

      # No delegation instance created (uses primary)
      refute(swarm.delegation_instances.key?("backend@frontend"))
    end

    # Test: Nested lazy delegation works correctly
    def test_nested_lazy_delegation
      swarm = Swarm.new(name: "Test Swarm", scratchpad: @test_scratchpad)

      # frontend -> backend -> database
      swarm.add_agent(create_agent(
        name: :database,
        description: "Database agent",
        model: "gpt-4o-mini",
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
        name: :frontend,
        description: "Frontend developer",
        model: "gpt-4o-mini",
        delegates_to: [:backend],
        directory: ".",
      ))

      swarm.lead = :frontend

      # Initialize agents
      swarm.agent(:frontend)

      # Before force initialization: no delegation instances
      assert_empty(swarm.delegation_instances)

      # Force initialization of all lazy delegates (cascading)
      swarm.initialize_lazy_delegates!

      # Both backend@frontend and database@backend@frontend should exist
      assert(swarm.delegation_instances.key?("backend@frontend"))
      assert(swarm.delegation_instances.key?("database@backend@frontend"))
    end

    # Test: Lazy initialization emits events
    def test_lazy_initialization_emits_events
      swarm = create_swarm_with_delegation

      # Setup event collection
      events = []
      Fiber[:log_subscriptions] = []
      LogCollector.subscribe { |event| events << event }
      LogStream.emitter = LogCollector

      # Trigger agent initialization
      swarm.agent(:frontend)

      # Force lazy delegate initialization
      swarm.initialize_lazy_delegates!

      # Check for lazy initialization events
      lazy_start_events = events.select { |e| e[:type] == "agent_lazy_initialization_start" }
      lazy_complete_events = events.select { |e| e[:type] == "agent_lazy_initialization_complete" }

      assert_equal(1, lazy_start_events.size, "Should emit lazy_initialization_start event")
      assert_equal(1, lazy_complete_events.size, "Should emit lazy_initialization_complete event")

      start_event = lazy_start_events.first

      assert_equal("backend@frontend", start_event[:instance_name])
      assert_equal(:backend, start_event[:base_name])
    ensure
      LogStream.emitter = nil
    end

    # Test: Multiple delegators to same target create separate lazy loaders
    def test_multiple_delegators_create_separate_lazy_loaders
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

      swarm.lead = :frontend

      # Initialize
      swarm.agent(:frontend)

      frontend_tool = swarm.agent(:frontend).tools[:WorkWithDatabase]
      backend_tool = swarm.agent(:backend).tools[:WorkWithDatabase]

      # Both should be lazy but different instances
      assert_predicate(frontend_tool, :lazy?)
      assert_predicate(backend_tool, :lazy?)
      refute_same(frontend_tool.delegate_chat, backend_tool.delegate_chat)

      # Force initialization
      swarm.initialize_lazy_delegates!

      # Different delegation instances should be created
      assert(swarm.delegation_instances.key?("database@frontend"))
      assert(swarm.delegation_instances.key?("database@backend"))
      refute_same(
        swarm.delegation_instances["database@frontend"],
        swarm.delegation_instances["database@backend"],
      )
    end

    private

    def create_swarm_with_delegation
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
