# frozen_string_literal: true

require "test_helper"
require "async"
require "logger"

module SwarmSDK
  class Swarm
    class ParallelAgentInitializationTest < Minitest::Test
      def setup
        SwarmSDK.reset_config!

        @original_api_key = ENV["OPENAI_API_KEY"]
        ENV["OPENAI_API_KEY"] = "test-key-12345"

        SwarmSDK.configure do |config|
          config.openai_api_key = "test-key-12345"
        end

        @test_scratchpad = create_test_scratchpad
      end

      def teardown
        ENV["OPENAI_API_KEY"] = @original_api_key
        SwarmSDK.reset_config!
        cleanup_test_scratchpads
      end

      # Test that multiple agents are initialized when agent() is called
      def test_parallel_initialization_creates_all_agents
        swarm = build_multi_agent_swarm

        # Trigger initialization via agent()
        swarm.agent(:lead)

        # All agents should be initialized
        assert_includes(swarm.agent_names, :lead)
        assert_includes(swarm.agent_names, :backend)
        assert_includes(swarm.agent_names, :frontend)

        # Verify agents are accessible
        assert(swarm.agent(:lead))
        assert(swarm.agent(:backend))
        assert(swarm.agent(:frontend))
      end

      # Test that parallel initialization works with a single agent
      def test_parallel_initialization_with_single_agent
        swarm = SwarmSDK::Swarm.new(name: "Single Agent Swarm", scratchpad: @test_scratchpad)
        swarm.add_agent(create_agent(name: :solo, description: "Solo agent"))
        swarm.lead = :solo

        # Trigger initialization
        swarm.agent(:solo)

        assert_equal([:solo], swarm.agent_names)
        assert(swarm.agent(:solo))
      end

      # Test that delegation instances are created properly
      def test_parallel_initialization_creates_delegation_instances
        swarm = build_swarm_with_delegations

        # Trigger initialization
        swarm.agent(:lead)

        # Delegation instances should be created for isolated delegates
        # (default is shared_across_delegations: false)
        delegation_instances = swarm.delegation_instances

        assert_predicate(delegation_instances, :any?, "Expected delegation instances to be created")
        assert(delegation_instances.key?("worker_a@lead"), "Expected worker_a@lead delegation instance")
        assert(delegation_instances.key?("worker_b@lead"), "Expected worker_b@lead delegation instance")
      end

      # Test that agents with shared_across_delegations use the same instance
      def test_parallel_initialization_with_shared_delegates
        swarm = SwarmSDK::Swarm.new(name: "Shared Delegate Swarm", scratchpad: @test_scratchpad)

        swarm.add_agent(create_agent(name: :lead, delegates_to: [:shared_worker]))
        swarm.add_agent(create_agent(
          name: :shared_worker,
          description: "Shared worker",
          shared_across_delegations: true,
        ))
        swarm.lead = :lead

        # Trigger initialization
        swarm.agent(:lead)

        # Shared worker should be a primary agent, not a delegation instance
        assert(swarm.agent(:shared_worker))
        refute(swarm.delegation_instances.key?("shared_worker@lead"))
      end

      # Test that errors in agent creation are properly raised
      def test_parallel_initialization_raises_on_invalid_tool
        swarm = SwarmSDK::Swarm.new(name: "Error Swarm", scratchpad: @test_scratchpad)

        swarm.add_agent(create_agent(
          name: :lead,
          tools: [:NonExistentTool],
        ))
        swarm.lead = :lead

        # Should raise ConfigurationError when trying to create the agent
        error = assert_raises(SwarmSDK::ConfigurationError) do
          swarm.agent(:lead)
        end

        # Error message includes agent name and original error
        assert_match(/Agent 'lead' initialization failed/, error.message)
        assert_match(/NonExistentTool/, error.message)
      end

      # Test that multiple initialization errors emit events and raise first error
      def test_parallel_initialization_emits_events_for_multiple_errors
        swarm = SwarmSDK::Swarm.new(name: "Multi Error Swarm", scratchpad: @test_scratchpad)

        # Create multiple agents with invalid tools
        swarm.add_agent(create_agent(name: :agent1, tools: [:InvalidTool1]))
        swarm.add_agent(create_agent(name: :agent2, tools: [:InvalidTool2]))
        swarm.add_agent(create_agent(name: :agent3, tools: [:InvalidTool3]))
        swarm.lead = :agent1

        # Setup event collection
        events = []
        Fiber[:log_subscriptions] = []
        SwarmSDK::LogCollector.subscribe { |event| events << event }
        SwarmSDK::LogStream.emitter = SwarmSDK::LogCollector

        # Should raise first error encountered
        error = assert_raises(SwarmSDK::ConfigurationError) do
          swarm.agent(:agent1)
        end

        # Error should mention agent initialization failure
        assert_match(/Agent '.*' initialization failed/, error.message)
        assert_match(/InvalidTool/, error.message)

        # All three errors should be emitted as events
        error_events = events.select { |e| e[:type] == "agent_initialization_error" }

        assert_equal(3, error_events.size, "Should emit event for each failed agent")

        # Verify events have correct structure
        error_events.each do |event|
          assert(event[:agent])
          assert_equal("SwarmSDK::ConfigurationError", event[:error_class])
          assert_match(/InvalidTool/, event[:error_message])
        end
      ensure
        # Cleanup
        SwarmSDK::LogStream.emitter = nil
        Fiber[:log_subscriptions] = nil
      end

      # Test that invalid delegation target raises error
      def test_parallel_initialization_raises_on_invalid_delegation
        swarm = SwarmSDK::Swarm.new(name: "Invalid Delegation Swarm", scratchpad: @test_scratchpad)

        swarm.add_agent(create_agent(
          name: :lead,
          delegates_to: [:nonexistent_agent],
        ))
        swarm.lead = :lead

        error = assert_raises(SwarmSDK::ConfigurationError) do
          swarm.agent(:lead)
        end

        assert_match(/unknown agent 'nonexistent_agent'/, error.message)
      end

      # Test that parallel initialization doesn't lose any agents
      def test_parallel_initialization_preserves_all_agents
        # Create a swarm with many agents to test parallel execution
        swarm = SwarmSDK::Swarm.new(name: "Many Agents Swarm", scratchpad: @test_scratchpad)

        agent_names = (1..10).map { |i| :"agent_#{i}" }

        agent_names.each do |name|
          swarm.add_agent(create_agent(name: name, description: "Agent #{name}"))
        end

        swarm.lead = :agent_1

        # Trigger initialization
        swarm.agent(:agent_1)

        # All agents should be present
        agent_names.each do |name|
          assert_includes(swarm.agent_names, name, "Agent #{name} should be initialized")
          assert(swarm.agent(name), "Agent #{name} should be accessible")
        end
      end

      # Test that parallel initialization works with complex delegation chains
      def test_parallel_initialization_with_nested_delegations
        swarm = SwarmSDK::Swarm.new(name: "Nested Delegation Swarm", scratchpad: @test_scratchpad)

        # lead -> middle -> worker
        swarm.add_agent(create_agent(name: :lead, delegates_to: [:middle]))
        swarm.add_agent(create_agent(name: :middle, delegates_to: [:worker]))
        swarm.add_agent(create_agent(name: :worker))
        swarm.lead = :lead

        # Trigger initialization
        swarm.agent(:lead)

        # Delegation instances should be created
        delegation_instances = swarm.delegation_instances

        assert(delegation_instances.key?("middle@lead"), "Expected middle@lead delegation instance")
      end

      # Test parallel initialization with mixed shared and isolated delegates
      def test_parallel_initialization_with_mixed_delegation_modes
        swarm = SwarmSDK::Swarm.new(name: "Mixed Delegation Swarm", scratchpad: @test_scratchpad)

        swarm.add_agent(create_agent(
          name: :lead,
          delegates_to: [:shared_worker, :isolated_worker],
        ))
        swarm.add_agent(create_agent(
          name: :shared_worker,
          shared_across_delegations: true,
        ))
        swarm.add_agent(create_agent(
          name: :isolated_worker,
          shared_across_delegations: false,
        ))
        swarm.lead = :lead

        # Trigger initialization
        swarm.agent(:lead)

        # Shared worker should be a primary agent
        assert(swarm.agent(:shared_worker))
        refute(swarm.delegation_instances.key?("shared_worker@lead"))

        # Isolated worker should be a delegation instance
        assert(swarm.delegation_instances.key?("isolated_worker@lead"))
      end

      # Test that agents are lazily initialized (not before agent() or execute())
      def test_agents_initialized_lazily_on_first_access
        swarm = build_multi_agent_swarm

        # Before agent() call, agents hash should be empty
        assert_predicate(swarm.agents, :empty?, "Agents should not be initialized before access")

        # Trigger initialization
        swarm.agent(:lead)

        # After agent() call, agents hash should be populated
        refute_predicate(swarm.agents, :empty?, "Agents should be initialized after access")
      end

      # Test that multiple agent() calls don't reinitialize agents
      def test_parallel_initialization_only_happens_once
        swarm = build_multi_agent_swarm

        # First access
        lead_agent_first = swarm.agent(:lead)
        backend_agent_first = swarm.agent(:backend)

        # Second access
        lead_agent_second = swarm.agent(:lead)
        backend_agent_second = swarm.agent(:backend)

        # Agent instances should be the same (not recreated)
        assert_same(lead_agent_first, lead_agent_second)
        assert_same(backend_agent_first, backend_agent_second)
      end

      # Test that swarm with no lead agent raises error
      def test_parallel_initialization_with_no_lead_agent
        swarm = SwarmSDK::Swarm.new(name: "Empty Swarm", scratchpad: @test_scratchpad)
        swarm.add_agent(create_agent(name: :orphan))
        stub_llm_request(mock_llm_response(content: "test"))

        error = assert_raises(SwarmSDK::ConfigurationError) do
          capture_io { swarm.execute("test") }
        end

        assert_match(/No lead agent set/, error.message)
      end

      # Test context breakdown after parallel initialization
      def test_context_breakdown_after_parallel_initialization
        swarm = build_multi_agent_swarm

        # Trigger initialization
        swarm.agent(:lead)

        # Context breakdown should include all agents
        breakdown = swarm.context_breakdown

        assert(breakdown.key?(:lead))
        assert(breakdown.key?(:backend))
        assert(breakdown.key?(:frontend))
      end

      # Test cleanup clears delegation instances
      def test_cleanup_clears_delegation_instances_after_parallel_init
        swarm = build_swarm_with_delegations

        # Trigger initialization
        swarm.agent(:lead)

        # Verify delegation instances exist
        refute_predicate(swarm.delegation_instances, :empty?, "Should have delegation instances")

        # Cleanup
        swarm.cleanup

        # Delegation instances should be cleared
        assert_predicate(swarm.delegation_instances, :empty?, "Cleanup should clear delegation instances")
      end

      private

      def build_multi_agent_swarm
        swarm = SwarmSDK::Swarm.new(name: "Multi Agent Swarm", scratchpad: @test_scratchpad)

        swarm.add_agent(create_agent(name: :lead, description: "Lead agent"))
        swarm.add_agent(create_agent(name: :backend, description: "Backend agent"))
        swarm.add_agent(create_agent(name: :frontend, description: "Frontend agent"))
        swarm.lead = :lead

        swarm
      end

      def build_swarm_with_delegations
        swarm = SwarmSDK::Swarm.new(name: "Delegation Swarm", scratchpad: @test_scratchpad)

        swarm.add_agent(create_agent(
          name: :lead,
          delegates_to: [:worker_a, :worker_b],
        ))
        swarm.add_agent(create_agent(name: :worker_a))
        swarm.add_agent(create_agent(name: :worker_b))
        swarm.lead = :lead

        swarm
      end
    end
  end
end
