# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ComposableSwarmsIntegrationTest < Minitest::Test
    def setup
      # Silence test output
      @original_logger_level = RubyLLM.logger.level
      RubyLLM.logger.level = Logger::ERROR
      @fixture_dir = File.expand_path("fixtures/composable_swarms", __dir__)
    end

    def teardown
      RubyLLM.logger.level = @original_logger_level
    end

    def test_swarm_loader_loads_from_ruby_file
      file_path = File.join(@fixture_dir, "code_review.rb")
      swarm = SwarmLoader.load_from_file(
        file_path,
        swarm_id: "main/code_review",
        parent_swarm_id: "main",
      )

      assert_equal("main/code_review", swarm.swarm_id)
      assert_equal("main", swarm.parent_swarm_id)
      assert_equal("Code Review Team", swarm.name)
      assert_equal(:lead_reviewer, swarm.lead_agent)
    end

    def test_swarm_loader_loads_from_yaml_file
      file_path = File.join(@fixture_dir, "testing.yml")
      swarm = SwarmLoader.load_from_file(
        file_path,
        swarm_id: "main/testing",
        parent_swarm_id: "main",
      )

      assert_equal("main/testing", swarm.swarm_id)
      assert_equal("main", swarm.parent_swarm_id)
      assert_equal("Testing Team", swarm.name)
      assert_equal(:tester, swarm.lead_agent)
    end

    def test_swarm_registry_loads_and_caches_swarm
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      file_path = File.join(@fixture_dir, "code_review.rb")
      registry.register("code_review", source: { type: :file, value: file_path }, keep_context: true)

      # First load
      swarm1 = registry.load_swarm("code_review")

      assert_equal("main/code_review", swarm1.swarm_id)

      # Second load should return cached instance
      swarm2 = registry.load_swarm("code_review")

      assert_same(swarm1, swarm2, "Expected cached swarm instance")
    end

    def test_swarm_registry_reset_if_needed_respects_keep_context
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      file_path = File.join(@fixture_dir, "code_review.rb")
      registry.register("code_review", source: { type: :file, value: file_path }, keep_context: false)

      # Load and use swarm
      swarm = registry.load_swarm("code_review")

      # Create mock to verify reset is called
      reset_called = false
      swarm.define_singleton_method(:reset_context!) { reset_called = true }

      # Reset should be called because keep_context: false
      registry.reset_if_needed("code_review")

      assert(reset_called, "Expected reset_context! to be called when keep_context: false")
    end

    def test_swarm_registry_reset_if_needed_skips_when_keep_context_true
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      file_path = File.join(@fixture_dir, "code_review.rb")
      registry.register("code_review", source: { type: :file, value: file_path }, keep_context: true)

      # Load and use swarm
      swarm = registry.load_swarm("code_review")

      # Create mock to verify reset is NOT called
      reset_called = false
      swarm.define_singleton_method(:reset_context!) { reset_called = true }

      # Reset should NOT be called because keep_context: true
      registry.reset_if_needed("code_review")

      refute(reset_called, "Expected reset_context! to NOT be called when keep_context: true")
    end

    def test_swarm_registry_shutdown_all_cleans_up_swarms
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      file_path = File.join(@fixture_dir, "code_review.rb")
      registry.register("code_review", source: { type: :file, value: file_path })

      # Load swarm
      swarm = registry.load_swarm("code_review")

      # Track cleanup
      cleanup_called = false
      swarm.define_singleton_method(:cleanup) { cleanup_called = true }

      # Shutdown should cleanup
      registry.shutdown_all

      assert(cleanup_called, "Expected cleanup to be called on shutdown")
    end

    def test_swarm_loader_loads_from_yaml_string
      yaml_content = <<~YAML
        version: 2
        swarm:
          id: testing_team
          name: "Testing Team"
          lead: tester
          agents:
            tester:
              description: "Test specialist"
              model: gpt-4o-mini
              system: "You test code"
              tools:
                - Think
      YAML

      swarm = SwarmLoader.load_from_yaml_string(
        yaml_content,
        swarm_id: "main/testing",
        parent_swarm_id: "main",
      )

      assert_equal("main/testing", swarm.swarm_id)
      assert_equal("main", swarm.parent_swarm_id)
      assert_equal("Testing Team", swarm.name)
      assert_equal(:tester, swarm.lead_agent)
    end

    def test_swarm_loader_loads_from_block
      swarm_block = proc do
        id("testing_team")
        name("Testing Team")
        lead(:tester)

        agent(:tester) do
          model("gpt-4o-mini")
          description("Test specialist")
          system("You test code")
          tools(:Think)
        end
      end

      swarm = SwarmLoader.load_from_block(
        swarm_block,
        swarm_id: "main/testing",
        parent_swarm_id: "main",
      )

      assert_equal("main/testing", swarm.swarm_id)
      assert_equal("main", swarm.parent_swarm_id)
      assert_equal("Testing Team", swarm.name)
      assert_equal(:tester, swarm.lead_agent)
    end

    def test_swarm_registry_loads_from_yaml_string
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      yaml_content = <<~YAML
        version: 2
        swarm:
          id: testing_team
          name: "Testing Team"
          lead: tester
          agents:
            tester:
              description: "Test specialist"
              model: gpt-4o-mini
              system: "You test code"
              tools:
                - Think
      YAML

      registry.register("testing", source: { type: :yaml, value: yaml_content })

      swarm = registry.load_swarm("testing")

      assert_equal("main/testing", swarm.swarm_id)
      assert_equal("main", swarm.parent_swarm_id)
      assert_equal("Testing Team", swarm.name)
    end

    def test_swarm_registry_loads_from_block
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      swarm_block = proc do
        id("testing_team")
        name("Testing Team")
        lead(:tester)

        agent(:tester) do
          model("gpt-4o-mini")
          description("Test specialist")
          system("You test code")
          tools(:Think)
        end
      end

      registry.register("testing", source: { type: :block, value: swarm_block })

      swarm = registry.load_swarm("testing")

      assert_equal("main/testing", swarm.swarm_id)
      assert_equal("main", swarm.parent_swarm_id)
      assert_equal("Testing Team", swarm.name)
    end

    def test_end_to_end_dsl_with_inline_block
      # Create parent swarm with inline sub-swarm definition
      swarm = SwarmSDK.build do
        id("main")
        name("Main Swarm")
        lead(:backend)

        swarms do
          register("testing", keep_context: false) do
            id("testing_team")
            name("Testing Team")
            lead(:tester)

            agent(:tester) do
              model("gpt-4o-mini")
              description("Test specialist")
              system("When asked to test, respond: 'Tests passed'")
              tools(:Think)
            end
          end
        end

        agent(:backend) do
          model("gpt-4o-mini")
          description("Backend dev")
          system("You build APIs")
          delegates_to("testing")
        end
      end

      # Verify swarm structure
      assert_equal("main", swarm.swarm_id)
      assert(swarm.swarm_registry.registered?("testing"))

      # This would require actual LLM execution to fully test
      # The structure is validated above
    end

    def test_end_to_end_dsl_with_yaml_string
      yaml_testing_swarm = <<~YAML
        version: 2
        swarm:
          id: testing_team
          name: "Testing Team"
          lead: tester
          agents:
            tester:
              description: "Test specialist"
              model: gpt-4o-mini
              system: "You test code"
              tools:
                - Think
      YAML

      swarm = SwarmSDK.build do
        id("main")
        name("Main Swarm")
        lead(:backend)

        swarms do
          register("testing", yaml: yaml_testing_swarm)
        end

        agent(:backend) do
          model("gpt-4o-mini")
          description("Backend dev")
          system("You build APIs")
          delegates_to("testing")
        end
      end

      # Verify swarm structure
      assert_equal("main", swarm.swarm_id)
      assert(swarm.swarm_registry.registered?("testing"))
    end

    def test_hierarchical_swarm_ids_in_events
      # Create parent swarm with registry
      swarm = SwarmSDK.build do
        id("main")
        name("Main Swarm")
        lead(:backend)

        agent(:backend) do
          model("gpt-4o-mini")
          description("Backend dev")
          system("You build APIs")
        end
      end

      # Verify swarm_id is set correctly
      assert_equal("main", swarm.swarm_id)
      assert_nil(swarm.parent_swarm_id)
    end

    def test_workflow_accepts_swarm_id_and_registry_config
      # Build via DSL which properly sets up nodes
      orchestrator = SwarmSDK.workflow do
        id("dev_workflow")
        name("Dev Workflow")
        start_node(:planning)

        agent(:backend) do
          model("gpt-4o-mini")
          description("Backend dev")
          system("You build APIs")
        end

        node(:planning) do
          lead(:backend)
          agent(:backend)
        end
      end

      # Verify orchestrator type and properties
      assert_instance_of(Workflow, orchestrator)
      assert_equal("Dev Workflow", orchestrator.swarm_name)
      assert_equal(:planning, orchestrator.start_node)
    end
  end
end
