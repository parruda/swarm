# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class WorkflowTest < Minitest::Test
    def setup
      # Reset logging state before each test (in case previous test failed)
      begin
        SwarmSDK::LogStream.reset!
      rescue StandardError
        nil
      end

      begin
        SwarmSDK::LogCollector.reset!
      rescue StandardError
        nil
      end

      @model_id = "gpt-4o-mini"
      @provider = "openai"
    end

    def teardown
      # Use begin/ensure to guarantee cleanup even if reset! raises
      begin
        SwarmSDK::LogStream.reset!
      rescue StandardError
        nil
      end

      begin
        SwarmSDK::LogCollector.reset!
      rescue StandardError
        nil
      end
    end

    def test_basic_two_node_workflow
      swarm = SwarmSDK.workflow do
        name("Planning and Implementation")

        agent(:planner) do
          model(@model_id)
          provider(@provider)
          description("Creates plans")
          system_prompt("You are a planner. Create a brief plan.")
          tools(:Read)
          coding_agent(false)
        end

        agent(:implementer) do
          model(@model_id)
          provider(@provider)
          description("Implements plans")
          system_prompt("You are an implementer. Say 'Implemented based on plan'")
          tools(:Read)
          coding_agent(false)
        end

        node(:planning) do
          agent(:planner)
        end

        node(:implementation) do
          agent(:implementer)
          depends_on(:planning)
        end

        start_node(:planning)
      end

      # Verify it's a Workflow
      assert_instance_of(Workflow, swarm)

      # Verify configuration
      assert_equal("Planning and Implementation", swarm.swarm_name)
      assert_equal(:planning, swarm.start_node)
      assert_equal(2, swarm.nodes.size)

      # Verify node configuration
      planning_node = swarm.nodes[:planning]

      assert_equal(:planning, planning_node.name)
      assert_equal(1, planning_node.agent_configs.size)
      assert_equal(:planner, planning_node.agent_configs.first[:agent])
      assert_empty(planning_node.dependencies)

      implementation_node = swarm.nodes[:implementation]

      assert_equal(:implementation, implementation_node.name)
      assert_equal(1, implementation_node.agent_configs.size)
      assert_equal(:implementer, implementation_node.agent_configs.first[:agent])
      assert_equal([:planning], implementation_node.dependencies)
    end

    def test_node_with_delegation
      swarm = SwarmSDK.workflow do
        name("Complex Workflow")

        agent(:lead) do
          model(@model_id)
          provider(@provider)
          description("Lead agent")
          system_prompt("You are the lead")
          coding_agent(false)
        end

        agent(:helper1) do
          model(@model_id)
          provider(@provider)
          description("Helper 1")
          system_prompt("You help")
          coding_agent(false)
        end

        agent(:helper2) do
          model(@model_id)
          provider(@provider)
          description("Helper 2")
          system_prompt("You also help")
          coding_agent(false)
        end

        node(:work) do
          agent(:lead).delegates_to(:helper1, :helper2)
          agent(:helper1).delegates_to(:helper2)
          # helper2 is auto-added (no need to declare)
        end

        start_node(:work)
      end

      # Verify delegation configuration
      work_node = swarm.nodes[:work]

      assert_equal(3, work_node.agent_configs.size)

      # Check lead delegates to both helpers
      lead_config = work_node.agent_configs.find { |ac| ac[:agent] == :lead }

      assert_equal([:helper1, :helper2], lead_config[:delegates_to])

      # Check helper1 delegates to helper2
      helper1_config = work_node.agent_configs.find { |ac| ac[:agent] == :helper1 }

      assert_equal([:helper2], helper1_config[:delegates_to])

      # Check helper2 has no delegation
      helper2_config = work_node.agent_configs.find { |ac| ac[:agent] == :helper2 }

      assert_empty(helper2_config[:delegates_to])
    end

    def test_explicit_lead_in_node
      swarm = SwarmSDK.workflow do
        name("Lead Override")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        agent(:agent2) do
          model(@model_id)
          provider(@provider)
          description("Agent 2")
          system_prompt("Agent 2")
          coding_agent(false)
        end

        node(:work) do
          agent(:agent1)
          agent(:agent2)
          lead(:agent2) # Explicit lead (not first agent)
        end

        start_node(:work)
      end

      work_node = swarm.nodes[:work]

      assert_equal(:agent2, work_node.lead_agent)
    end

    def test_input_and_output_transformers
      swarm = SwarmSDK.workflow do
        name("Transformer Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        agent(:agent2) do
          model(@model_id)
          provider(@provider)
          description("Agent 2")
          system_prompt("Agent 2")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)

          output do |result|
            "TRANSFORMED: #{result.content}"
          end
        end

        node(:second) do
          agent(:agent2)
          depends_on(:first)

          input do |previous_result|
            "INPUT: #{previous_result.content}"
          end
        end

        start_node(:first)
      end

      first_node = swarm.nodes[:first]

      assert(first_node.output_transformer)

      second_node = swarm.nodes[:second]

      assert(second_node.input_transformer)
    end

    def test_missing_start_node_raises_error
      error = assert_raises(ConfigurationError) do
        SwarmSDK.workflow do
          name("Missing Start")

          agent(:agent1) do
            model(@model_id)
            provider(@provider)
            description("Agent")
            system_prompt("Agent")
            coding_agent(false)
          end

          node(:work) do
            agent(:agent1)
          end

          # Missing: start_node :work
        end
      end

      assert_match(/start_node not set/, error.message)
    end

    def test_invalid_start_node_raises_error
      error = assert_raises(ConfigurationError) do
        SwarmSDK.workflow do
          name("Invalid Start")

          agent(:agent1) do
            model(@model_id)
            provider(@provider)
            description("Agent")
            system_prompt("Agent")
            coding_agent(false)
          end

          node(:work) do
            agent(:agent1)
          end

          start_node(:nonexistent)
        end
      end

      assert_match(/start_node 'nonexistent' not found/, error.message)
    end

    def test_undefined_agent_in_node_raises_error
      error = assert_raises(ConfigurationError) do
        SwarmSDK.workflow do
          name("Undefined Agent")

          agent(:agent1) do
            model(@model_id)
            provider(@provider)
            description("Agent 1")
            system_prompt("Agent 1")
            coding_agent(false)
          end

          node(:work) do
            agent(:nonexistent_agent)
          end

          start_node(:work)
        end
      end

      assert_match(/Agent 'nonexistent_agent' referenced in node but not found/, error.message)
    end

    def test_circular_dependency_raises_error
      error = assert_raises(CircularDependencyError) do
        SwarmSDK.workflow do
          name("Circular")

          agent(:agent1) do
            model(@model_id)
            provider(@provider)
            description("Agent 1")
            system_prompt("Agent 1")
            coding_agent(false)
          end

          node(:node1) do
            agent(:agent1)
            depends_on(:node2)
          end

          node(:node2) do
            agent(:agent1)
            depends_on(:node1)
          end

          start_node(:node1)
        end
      end

      assert_match(/Circular dependency/, error.message)
      assert_match(/goto_node/, error.message)
    end

    def test_halt_workflow_from_input_transformer
      swarm = SwarmSDK.workflow do
        name("Halt Workflow")

        # Use agent-less node to avoid LLM calls
        node(:validation) do
          input do |ctx|
            # Halt if input too long
            if ctx.content.length > 10
              ctx.halt_workflow(content: "ERROR: Input too long")
            else
              ctx.content
            end
          end

          output do |ctx|
            "Validated: #{ctx.content}"
          end
        end

        start_node(:validation)
      end

      # Execute with long input (should halt)
      result = swarm.execute("This is a very long input that exceeds the limit")

      assert_equal("ERROR: Input too long", result.content)
      assert_match(/halted/, result.agent)
    end

    def test_goto_node_from_output_transformer
      swarm = SwarmSDK.workflow do
        name("Goto Node Workflow")

        # Use agent-less nodes to avoid LLM calls
        node(:step1) do
          # Agent-less node with output transformer
          output do |ctx|
            # Jump to step3, skipping step2
            ctx.goto_node(:step3, content: "Went to step3 from step1")
          end
        end

        node(:step2) do
          # This should be skipped
          output do |ctx|
            "Step 2: #{ctx.content}"
          end
          depends_on(:step1)
        end

        node(:step3) do
          # Final node
          output do |ctx|
            "Step 3: #{ctx.content}"
          end
          depends_on(:step2)
        end

        start_node(:step1)
      end

      # Execute - should go step1 -> step3 (skipping step2)
      result = swarm.execute("Start workflow")

      # Result should contain the goto message
      assert_match(/Step 3.*step3 from step1/, result.content)
      refute_match(/Step 2/, result.content)
    end

    def test_skip_execution_with_context_method
      swarm = SwarmSDK.workflow do
        name("Skip Execution")

        # Use node with agent but skip execution based on input
        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("You process data")
          coding_agent(false)
        end

        node(:check_cache) do
          agent(:agent1)

          input do |ctx|
            # Skip LLM call if input is "cached" - using context method
            # This avoids the expensive LLM call when we have cached data
            if ctx.content == "cached"
              ctx.skip_execution(content: "Using cached result")
            else
              ctx.content
            end
          end
        end

        start_node(:check_cache)
      end

      # Execute with cached input - should skip LLM execution
      result = swarm.execute("cached")

      assert_equal("Using cached result", result.content)
      assert_match(/skipped/, result.agent)
    end

    def test_node_without_agents_or_transformers_raises_error
      error = assert_raises(ConfigurationError) do
        SwarmSDK.workflow do
          name("Empty Node")

          agent(:agent1) do
            model(@model_id)
            provider(@provider)
            description("Agent 1")
            system_prompt("Agent 1")
            coding_agent(false)
          end

          node(:empty) do
            # No agents AND no transformers - invalid!
          end

          start_node(:empty)
        end
      end

      assert_match(/must have at least one transformer/, error.message)
    end

    def test_traditional_swarm_still_works
      # Ensure non-node swarms still work (backward compatibility)
      swarm = SwarmSDK.build do
        name("Traditional Swarm")
        lead(:agent1)

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end
      end

      # Should be a regular Swarm, not Workflow
      assert_instance_of(Swarm, swarm)
      assert_equal(:agent1, swarm.lead_agent)
    end

    def test_agent_less_node_with_output_transformer
      swarm = SwarmSDK.workflow do
        name("Agent-less Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Say: original content")
          coding_agent(false)
        end

        node(:llm_node) do
          agent(:agent1)
        end

        node(:computation) do
          # No agents - pure computation
          output do |result|
            "TRANSFORMED: #{result.content.upcase}"
          end
        end

        node(:final) do
          agent(:agent1)
          depends_on(:computation)
        end

        start_node(:llm_node)
      end

      assert_instance_of(Workflow, swarm)

      # Verify computation node is agent-less
      computation_node = swarm.nodes[:computation]

      assert_predicate(computation_node, :agent_less?)
      assert_empty(computation_node.agent_configs)
    end

    def test_agent_less_node_with_input_transformer
      swarm = SwarmSDK.workflow do
        name("Agent-less Input Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:parse) do
          # Agent-less with input transformer
          input do |previous_result|
            parsed = previous_result.content.split("\n").first
            "PARSED: #{parsed}"
          end

          output(&:content)
        end

        node(:final) do
          agent(:agent1)
          depends_on(:parse)
        end

        start_node(:first)
      end

      parse_node = swarm.nodes[:parse]

      assert_predicate(parse_node, :agent_less?)
      assert(parse_node.input_transformer)
      assert(parse_node.output_transformer)
    end

    def test_agent_less_node_without_transformers_raises_error
      error = assert_raises(ConfigurationError) do
        SwarmSDK.workflow do
          name("Invalid Agent-less")

          agent(:agent1) do
            model(@model_id)
            provider(@provider)
            description("Agent 1")
            system_prompt("Agent 1")
            coding_agent(false)
          end

          node(:first) do
            agent(:agent1)
          end

          node(:bad_node) do
            # No agents AND no transformers - invalid!
          end

          start_node(:first)
        end
      end

      assert_match(/must have at least one transformer/, error.message)
    end

    def test_agent_less_node_only_input_transformer
      swarm = SwarmSDK.workflow do
        name("Agent-less Input Only")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:transform_only) do
          # Only input transformer, no output
          input do |previous_result|
            "TRANSFORMED: #{previous_result.content}"
          end
        end

        start_node(:first)
      end

      transform_node = swarm.nodes[:transform_only]

      assert_predicate(transform_node, :agent_less?)
      assert(transform_node.input_transformer)
      refute(transform_node.output_transformer)
    end

    def test_skip_execution_from_input_transformer
      swarm = SwarmSDK.workflow do
        name("Skip Execution Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("You should not see this")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:cached) do
          agent(:agent1)
          depends_on(:first)

          input do |previous_result|
            # Skip execution and return cached result
            { skip_execution: true, content: "CACHED: #{previous_result.content.upcase}" }
          end
        end

        start_node(:first)
      end

      assert_instance_of(Workflow, swarm)
      cached_node = swarm.nodes[:cached]

      refute_predicate(cached_node, :agent_less?)
    end

    def test_skip_execution_with_validation
      swarm = SwarmSDK.workflow do
        name("Validation Skip Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:validator) do
          agent(:agent1)
          depends_on(:first)

          input do |previous_result|
            if previous_result.content.length > 1000
              # Fail early
              { skip_execution: true, content: "ERROR: Input too long" }
            else
              previous_result.content
            end
          end
        end

        start_node(:first)
      end

      validator_node = swarm.nodes[:validator]

      assert(validator_node.input_transformer)
    end

    def test_skip_execution_with_string_keys
      # Test that string keys also work (not just symbol keys)
      swarm = SwarmSDK.workflow do
        name("String Keys Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:skip_node) do
          agent(:agent1)
          depends_on(:first)

          input do |_previous_result|
            # Return hash with string keys instead of symbol keys
            { "skip_execution" => true, "content" => "Skipped with string keys" }
          end
        end

        start_node(:first)
      end

      assert_instance_of(Workflow, swarm)
    end

    def test_conditional_skip_execution
      swarm = SwarmSDK.workflow do
        name("Conditional Skip Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:conditional) do
          agent(:agent1)
          depends_on(:first)

          input do |previous_result|
            # Sometimes skip, sometimes don't
            if previous_result.content.include?("skip")
              { skip_execution: true, content: "SKIPPED" }
            else
              "PROCESSING: #{previous_result.content}"
            end
          end
        end

        start_node(:first)
      end

      conditional_node = swarm.nodes[:conditional]

      assert(conditional_node.input_transformer)
    end

    def test_agent_less_nodes_emit_events_without_http_calls
      # Test node events using only agent-less nodes (no HTTP calls)
      swarm = SwarmSDK.workflow do
        name("Agent-less Event Test")

        node(:parse) do
          output do |_input|
            "parsed data"
          end
        end

        node(:transform) do
          output do |result|
            "transformed: #{result.content.upcase}"
          end
          depends_on(:parse)
        end

        start_node(:parse)
      end

      logs = []
      swarm.execute("test input") do |log|
        logs << log
      end

      # Check node_start events
      node_starts = logs.select { |l| l[:type] == "node_start" }

      assert_equal(2, node_starts.size, "Expected 2 node_start events, got #{node_starts.size}. All types: #{logs.map { |l| l[:type] }.uniq}")

      parse_start = node_starts.find { |e| e[:node] == "parse" }

      assert(parse_start)
      assert(parse_start[:agent_less])
      assert_empty(parse_start[:agents])

      transform_start = node_starts.find { |e| e[:node] == "transform" }

      assert(transform_start)
      assert(transform_start[:agent_less])
      assert_equal(["parse"], transform_start[:dependencies])

      # Check node_stop events
      node_stops = logs.select { |l| l[:type] == "node_stop" }

      assert_equal(2, node_stops.size)

      node_stops.each do |stop|
        assert(stop[:agent_less])
        refute(stop[:skipped])
        assert(stop[:duration])
        assert_operator(stop[:duration], :>=, 0)
      end
    end

    def test_skip_execution_sets_skipped_flag_in_event
      swarm = SwarmSDK.workflow do
        name("Skip Flag Test")

        node(:first) do
          output { |_| "first" }
        end

        node(:maybe_skip) do
          input do |_previous|
            { skip_execution: true, content: "SKIPPED" }
          end

          output(&:content)
          depends_on(:first)
        end

        start_node(:first)
      end

      logs = []
      swarm.execute("test") do |log|
        logs << log
      end

      skip_stop = logs.find { |l| l[:type] == "node_stop" && l[:node] == "maybe_skip" }

      assert(skip_stop)
      assert(skip_stop[:skipped])
    end

    def test_auto_add_delegate_agents
      # Agents mentioned in delegates_to should be automatically added to the node
      swarm = SwarmSDK.workflow do
        name("Auto-add Test")

        agent(:backend) do
          model(@model_id)
          provider(@provider)
          description("Backend")
          system_prompt("Backend")
          coding_agent(false)
        end

        agent(:tester) do
          model(@model_id)
          provider(@provider)
          description("Tester")
          system_prompt("Tester")
          coding_agent(false)
        end

        agent(:database) do
          model(@model_id)
          provider(@provider)
          description("Database")
          system_prompt("Database")
          coding_agent(false)
        end

        node(:impl) do
          agent(:backend).delegates_to(:tester, :database)
          # tester and database are auto-added - no explicit declaration needed!
        end

        start_node(:impl)
      end

      impl_node = swarm.nodes[:impl]

      # Should have all 3 agents (backend + auto-added tester + database)
      agent_names = impl_node.agent_configs.map { |ac| ac[:agent] }

      assert_equal(3, impl_node.agent_configs.size)
      assert_includes(agent_names, :backend)
      assert_includes(agent_names, :tester)
      assert_includes(agent_names, :database)

      # Backend should delegate to both
      backend_config = impl_node.agent_configs.find { |ac| ac[:agent] == :backend }

      assert_equal([:tester, :database], backend_config[:delegates_to])

      # Auto-added agents should have empty delegation
      tester_config = impl_node.agent_configs.find { |ac| ac[:agent] == :tester }

      assert_empty(tester_config[:delegates_to])

      database_config = impl_node.agent_configs.find { |ac| ac[:agent] == :database }

      assert_empty(database_config[:delegates_to])
    end

    def test_auto_add_preserves_explicit_delegation
      # If an agent is explicitly declared with delegation, don't override it
      swarm = SwarmSDK.workflow do
        name("Preserve Delegation Test")

        agent(:a) do
          model(@model_id)
          provider(@provider)
          description("A")
          system_prompt("A")
          coding_agent(false)
        end

        agent(:b) do
          model(@model_id)
          provider(@provider)
          description("B")
          system_prompt("B")
          coding_agent(false)
        end

        agent(:c) do
          model(@model_id)
          provider(@provider)
          description("C")
          system_prompt("C")
          coding_agent(false)
        end

        node(:test) do
          agent(:a).delegates_to(:b)
          agent(:b).delegates_to(:c) # Explicit: b delegates to c
          # c is auto-added
        end

        start_node(:test)
      end

      test_node = swarm.nodes[:test]

      # All 3 should be present
      assert_equal(3, test_node.agent_configs.size)

      # b should keep its explicit delegation
      b_config = test_node.agent_configs.find { |ac| ac[:agent] == :b }

      assert_equal([:c], b_config[:delegates_to])

      # c should be auto-added with empty delegation
      c_config = test_node.agent_configs.find { |ac| ac[:agent] == :c }

      assert_empty(c_config[:delegates_to])
    end

    def test_reset_context_default_behavior
      # Test that by default, agents get fresh context in each node
      swarm = SwarmSDK.workflow do
        name("Fresh Context Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:node1) do
          agent(:agent1)  # Default: reset_context = true
        end

        node(:node2) do
          agent(:agent1)  # Should get fresh context
          depends_on(:node1)
        end

        start_node(:node1)
      end

      # Verify agent configs have reset_context: true by default
      node1 = swarm.nodes[:node1]
      node2 = swarm.nodes[:node2]

      assert(node1.agent_configs.first[:reset_context])
      assert(node2.agent_configs.first[:reset_context])
    end

    def test_reset_context_false_preserves_config
      # Test that reset_context: false is properly stored in config
      swarm = SwarmSDK.workflow do
        name("Preserve Context Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:node1) do
          agent(:agent1, reset_context: false)
        end

        node(:node2) do
          agent(:agent1, reset_context: false)
          depends_on(:node1)
        end

        start_node(:node1)
      end

      # Verify agent configs have reset_context: false
      node1 = swarm.nodes[:node1]
      node2 = swarm.nodes[:node2]

      refute(node1.agent_configs.first[:reset_context])
      refute(node2.agent_configs.first[:reset_context])
    end

    def test_reset_context_mixed_usage
      # Test that some agents can preserve context while others get fresh context
      swarm = SwarmSDK.workflow do
        name("Mixed Context Test")

        agent(:architect) do
          model(@model_id)
          provider(@provider)
          description("Architect")
          system_prompt("Architect")
          coding_agent(false)
        end

        agent(:reviewer) do
          model(@model_id)
          provider(@provider)
          description("Reviewer")
          system_prompt("Reviewer")
          coding_agent(false)
        end

        node(:node1) do
          agent(:architect, reset_context: false) # Preserve context
          agent(:reviewer) # Fresh context (default)
        end

        node(:node2) do
          agent(:architect, reset_context: false) # Should reuse cached instance
          agent(:reviewer) # Fresh instance
          depends_on(:node1)
        end

        start_node(:node1)
      end

      node1 = swarm.nodes[:node1]
      node2 = swarm.nodes[:node2]

      # Verify architect preserves context
      architect_config_1 = node1.agent_configs.find { |ac| ac[:agent] == :architect }
      architect_config_2 = node2.agent_configs.find { |ac| ac[:agent] == :architect }

      refute(architect_config_1[:reset_context])
      refute(architect_config_2[:reset_context])

      # Verify reviewer gets fresh context
      reviewer_config_1 = node1.agent_configs.find { |ac| ac[:agent] == :reviewer }
      reviewer_config_2 = node2.agent_configs.find { |ac| ac[:agent] == :reviewer }

      assert(reviewer_config_1[:reset_context])
      assert(reviewer_config_2[:reset_context])
    end

    # Tests for scratchpad modes
    def test_scratchpad_enabled_mode_shares_across_nodes
      swarm = SwarmSDK.workflow do
        name("Scratchpad Enabled Test")
        scratchpad(:enabled)

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("You are agent 1")
          coding_agent(false)
        end

        agent(:agent2) do
          model(@model_id)
          provider(@provider)
          description("Agent 2")
          system_prompt("You are agent 2")
          coding_agent(false)
        end

        node(:node1) do
          agent(:agent1)
        end

        node(:node2) do
          agent(:agent2)
          depends_on(:node1)
        end

        start_node(:node1)
      end

      # Verify scratchpad mode
      assert_equal(:enabled, swarm.scratchpad)
      assert_predicate(swarm, :scratchpad_enabled?)
      assert_predicate(swarm, :shared_scratchpad?)
      refute_predicate(swarm, :per_node_scratchpad?)

      # Verify both nodes will use the same scratchpad instance
      node1_scratchpad = swarm.scratchpad_for(:node1)
      node2_scratchpad = swarm.scratchpad_for(:node2)

      assert_same(node1_scratchpad, node2_scratchpad, "Nodes should share same scratchpad in :enabled mode")
    end

    def test_scratchpad_per_node_mode_isolates_nodes
      swarm = SwarmSDK.workflow do
        name("Scratchpad Per-Node Test")
        scratchpad(:per_node)

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("You are agent 1")
          coding_agent(false)
        end

        node(:node1) do
          agent(:agent1)
        end

        node(:node2) do
          agent(:agent1)
          depends_on(:node1)
        end

        start_node(:node1)
      end

      # Verify scratchpad mode
      assert_equal(:per_node, swarm.scratchpad)
      assert_predicate(swarm, :scratchpad_enabled?)
      refute_predicate(swarm, :shared_scratchpad?)
      assert_predicate(swarm, :per_node_scratchpad?)

      # Verify each node gets its own scratchpad instance (lazy init)
      node1_scratchpad = swarm.scratchpad_for(:node1)
      node2_scratchpad = swarm.scratchpad_for(:node2)

      refute_nil(node1_scratchpad)
      refute_nil(node2_scratchpad)
      refute_same(node1_scratchpad, node2_scratchpad, "Nodes should have separate scratchpads in :per_node mode")
    end

    def test_scratchpad_disabled_mode_returns_nil
      swarm = SwarmSDK.workflow do
        name("Scratchpad Disabled Test")
        scratchpad(:disabled)

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("You are agent 1")
          coding_agent(false)
        end

        node(:node1) do
          agent(:agent1)
        end

        start_node(:node1)
      end

      # Verify scratchpad mode
      assert_equal(:disabled, swarm.scratchpad)
      refute_predicate(swarm, :scratchpad_enabled?)
      refute_predicate(swarm, :shared_scratchpad?)

      # Verify scratchpad_for returns nil
      assert_nil(swarm.scratchpad_for(:node1))
      assert_empty(swarm.all_scratchpads)
    end

    # Tests for per-node tool overrides
    def test_per_node_tool_override_dsl
      swarm = SwarmSDK.workflow do
        name("Tool Override Test")

        agent(:backend) do
          model(@model_id)
          provider(@provider)
          description("Backend")
          system_prompt("You build APIs")
          tools(:Read, :Edit, :Write, :Bash)
          coding_agent(false)
        end

        node(:planning) do
          agent(:backend).tools(:Read, :Think)
        end

        node(:implementation) do
          agent(:backend).tools(:Read, :Edit, :Write)
        end

        start_node(:planning)
      end

      # Verify global definition has 4 tools
      global_def = swarm.agent_definitions[:backend]

      assert_equal(4, global_def.tools.size)

      # Verify planning node override
      planning_config = swarm.nodes[:planning].agent_configs.find { |ac| ac[:agent] == :backend }

      assert_equal([:Read, :Think], planning_config[:tools])

      # Verify implementation node override
      impl_config = swarm.nodes[:implementation].agent_configs.find { |ac| ac[:agent] == :backend }

      assert_equal([:Read, :Edit, :Write], impl_config[:tools])
    end

    def test_per_node_tool_override_yaml
      yaml = <<~YAML
        version: 2
        workflow:
          name: Tool Override YAML

          agents:
            backend:
              description: Backend
              model: #{@model_id}
              system_prompt: You build APIs
              tools:
                - Read
                - Edit
                - Write
                - Bash

          nodes:
            planning:
              agents:
                - agent: backend
                  tools:
                    - Read
                    - Think

            implementation:
              agents:
                - agent: backend
                  tools:
                    - Read
                    - Edit
                    - Write

          start_node: planning
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate
      swarm = config.to_swarm

      # Verify planning node override
      planning_config = swarm.nodes[:planning].agent_configs.find { |ac| ac[:agent] == :backend }

      assert_equal([:Read, :Think], planning_config[:tools])

      # Verify implementation node override
      impl_config = swarm.nodes[:implementation].agent_configs.find { |ac| ac[:agent] == :backend }

      assert_equal([:Read, :Edit, :Write], impl_config[:tools])
    end

    def test_per_node_nil_tools_uses_global
      swarm = SwarmSDK.workflow do
        name("Default Tools Test")

        agent(:backend) do
          model(@model_id)
          provider(@provider)
          description("Backend")
          system_prompt("You code")
          tools(:Read, :Write)
          coding_agent(false)
        end

        node(:planning) do
          agent(:backend) # No tools() called - should use global
        end

        start_node(:planning)
      end

      # Verify nil means use global
      planning_config = swarm.nodes[:planning].agent_configs.find { |ac| ac[:agent] == :backend }

      assert_nil(planning_config[:tools], "Nil tools should mean 'use global definition'")
    end

    def test_per_node_tool_override_combined_with_delegation
      swarm = SwarmSDK.workflow do
        name("Combined Override Test")

        agent(:backend) do
          model(@model_id)
          provider(@provider)
          description("Backend")
          system_prompt("You build")
          tools(:Read, :Write)
          coding_agent(false)
        end

        agent(:tester) do
          model(@model_id)
          provider(@provider)
          description("Tester")
          system_prompt("You test")
          tools(:Read, :Bash)
          coding_agent(false)
        end

        node(:implementation) do
          agent(:backend).delegates_to(:tester).tools(:Read, :Edit, :Write, :Bash)
        end

        start_node(:implementation)
      end

      # Verify both delegation and tools are set
      impl_config = swarm.nodes[:implementation].agent_configs.find { |ac| ac[:agent] == :backend }

      assert_equal([:tester], impl_config[:delegates_to])
      assert_equal([:Read, :Edit, :Write, :Bash], impl_config[:tools])
    end
  end
end
