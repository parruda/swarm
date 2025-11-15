# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Tests for YAML node workflow support
  class YAMLNodeSupportTest < Minitest::Test
    def setup
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure { |config| config.openai_api_key = "test-key-12345" }
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure { |config| config.openai_api_key = @original_api_key }
    end

    # Test: Basic node configuration
    def test_basic_node_configuration
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend developer"
              model: "gpt-4o-mini"
              directory: "."
            tester:
              description: "Testing agent"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            planning:
              agents:
                - agent: backend
            implementation:
              agents:
                - agent: backend
                  delegates_to: [tester]
                - agent: tester
              dependencies: [planning]
          start_node: planning
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify nodes were parsed
      assert_equal(2, config.nodes.size)
      assert(config.nodes.key?(:planning))
      assert(config.nodes.key?(:implementation))
      assert_equal(:planning, config.start_node)

      # Build swarm - should create Workflow
      result = config.to_swarm

      assert_instance_of(Workflow, result)
    end

    # Test: Node dependencies
    def test_node_dependencies
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            architect:
              description: "Architect"
              model: "gpt-4o-mini"
              directory: "."
            coder:
              description: "Coder"
              model: "gpt-4o-mini"
              directory: "."
            tester:
              description: "Tester"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            planning:
              agents:
                - agent: architect
            coding:
              agents:
                - agent: coder
              dependencies: [planning]
            testing:
              agents:
                - agent: tester
              dependencies: [coding]
          start_node: planning
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify dependencies parsed (as symbols after load)
      assert_equal(["planning"], config.nodes[:coding][:dependencies])
      assert_equal(["coding"], config.nodes[:testing][:dependencies])

      # Build should succeed
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end

    # Test: Node with delegation
    def test_node_with_delegation
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
            database:
              description: "Database"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            implementation:
              agents:
                - agent: backend
                  delegates_to: [database]
                - agent: database
          start_node: implementation
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify delegation in node config
      backend_config = config.nodes[:implementation][:agents].find { |a| a[:agent] == "backend" }

      assert_equal(["database"], backend_config[:delegates_to])

      # Build swarm
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end

    # Test: Node with lead override
    def test_node_with_lead_override
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
            reviewer:
              description: "Reviewer"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            review:
              agents:
                - agent: backend
                - agent: reviewer
              lead: reviewer
          start_node: review
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify lead override
      assert_equal("reviewer", config.nodes[:review][:lead])

      # Build swarm
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end

    # Test: Node with transformers
    def test_node_with_transformers
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            implementation:
              agents:
                - agent: backend
              input_command: "echo 'transformed'"
              input_timeout: 30
              output_command: "tee output.txt"
              output_timeout: 60
          start_node: implementation
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify transformers parsed
      assert_equal("echo 'transformed'", config.nodes[:implementation][:input_command])
      assert_equal(30, config.nodes[:implementation][:input_timeout])
      assert_equal("tee output.txt", config.nodes[:implementation][:output_command])
      assert_equal(60, config.nodes[:implementation][:output_timeout])

      # Build swarm
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end

    # Test: Missing start_node raises error
    def test_missing_start_node_raises_error
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            planning:
              agents:
                - agent: backend
          # Missing: start_node
      YAML

      config = Configuration.new(yaml)
      error = assert_raises(ConfigurationError) do
        config.load_and_validate
      end

      assert_match(/start_node.*field/i, error.message)
    end

    # Test: Invalid start_node raises error
    def test_invalid_start_node_raises_error
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            planning:
              agents:
                - agent: backend
          start_node: nonexistent
      YAML

      config = Configuration.new(yaml)
      error = assert_raises(ConfigurationError) do
        config.load_and_validate
      end

      assert_match(/start_node.*not found/i, error.message)
    end

    # Test: Node with undefined agent raises error
    def test_node_with_undefined_agent_raises_error
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            planning:
              agents:
                - agent: nonexistent
          start_node: planning
      YAML

      config = Configuration.new(yaml)
      error = assert_raises(ConfigurationError) do
        config.load_and_validate
      end

      assert_match(/references undefined agent/i, error.message)
    end

    # Test: Node with undefined dependency raises error
    def test_node_with_undefined_dependency_raises_error
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            implementation:
              agents:
                - agent: backend
              dependencies: [nonexistent]
          start_node: implementation
      YAML

      config = Configuration.new(yaml)

      error = assert_raises(ConfigurationError) do
        config.load_and_validate
      end

      assert_match(/depends on undefined node/i, error.message)
    end

    # Test: Node with reset_context
    def test_node_with_reset_context
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            first:
              agents:
                - agent: backend
            second:
              agents:
                - agent: backend
                  reset_context: false
              dependencies: [first]
          start_node: first
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify reset_context parsed
      backend_config = config.nodes[:second][:agents].find { |a| a[:agent] == "backend" }

      refute(backend_config[:reset_context])

      # Build swarm
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end

    # Test: Agent-less node (computation only)
    def test_agent_less_node_with_transformers
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Test Swarm"
          agents:
            backend:
              description: "Backend"
              model: "gpt-4o-mini"
              directory: "."
          nodes:
            preparation:
              agents:
                - agent: backend
            computation:
              # No agents - pure computation node
              input_command: "echo 'computed'"
            final:
              agents:
                - agent: backend
              dependencies: [computation]
          start_node: preparation
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Computation node should have no agents
      assert_nil(config.nodes[:computation][:agents])

      # Build swarm - should succeed (agent-less nodes allowed with transformers)
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end

    # Test: Complex multi-node workflow
    def test_complex_multi_node_workflow
      yaml = <<~YAML
        version: 2
        workflow:
          name: "Development Team"
          agents:
            coordinator:
              description: "Coordinator"
              model: "gpt-4o-mini"
              directory: "."
            backend:
              description: "Backend developer"
              model: "gpt-4o-mini"
              directory: "."
            frontend:
              description: "Frontend developer"
              model: "gpt-4o-mini"
              directory: "."
            tester:
              description: "Tester"
              model: "gpt-4o-mini"
              directory: "."
            database:
              description: "Database agent"
              model: "gpt-4o-mini"
              directory: "."
              shared_across_delegations: true
          nodes:
            planning:
              agents:
                - agent: coordinator
              output_command: "tee plan.txt"
            backend_dev:
              agents:
                - agent: backend
                  delegates_to: [database]
                - agent: database
              dependencies: [planning]
              input_command: "cat plan.txt"
            frontend_dev:
              agents:
                - agent: frontend
                  delegates_to: [database]
                - agent: database
              dependencies: [planning]
            testing:
              agents:
                - agent: tester
              dependencies: [backend_dev, frontend_dev]
          start_node: planning
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      # Verify all nodes parsed
      assert_equal(4, config.nodes.size)
      assert_equal(:planning, config.start_node)

      # Verify dependencies
      assert_equal(["planning"], config.nodes[:backend_dev][:dependencies])
      assert_equal(["planning"], config.nodes[:frontend_dev][:dependencies])
      assert_equal(["backend_dev", "frontend_dev"], config.nodes[:testing][:dependencies])

      # Verify transformers
      assert_equal("tee plan.txt", config.nodes[:planning][:output_command])
      assert_equal("cat plan.txt", config.nodes[:backend_dev][:input_command])

      # Verify shared_across_delegations works with nodes
      database_def = config.agents[:database]

      assert(database_def[:shared_across_delegations])

      # Build swarm
      orchestrator = config.to_swarm

      assert_instance_of(Workflow, orchestrator)
    end
  end
end
