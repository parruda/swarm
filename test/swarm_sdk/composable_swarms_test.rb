# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ComposableSwarmsTest < Minitest::Test
    def setup
      # Silence test output
      @original_logger_level = RubyLLM.logger.level
      RubyLLM.logger.level = Logger::ERROR
    end

    def teardown
      RubyLLM.logger.level = @original_logger_level
    end

    def test_swarm_registry_registers_and_checks_swarms
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      registry.register("code_review", source: { type: :file, value: "./swarms/code_review.rb" }, keep_context: true)

      assert(registry.registered?("code_review"))
      refute(registry.registered?("unknown"))
    end

    def test_swarm_registry_prevents_duplicate_registration
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      registry.register("code_review", source: { type: :file, value: "./swarms/code_review.rb" })

      error = assert_raises(ArgumentError) do
        registry.register("code_review", source: { type: :file, value: "./swarms/other.rb" })
      end

      assert_match(/already registered/, error.message)
    end

    def test_swarm_registry_raises_on_load_unregistered
      registry = SwarmRegistry.new(parent_swarm_id: "main")

      error = assert_raises(ConfigurationError) do
        registry.load_swarm("unknown")
      end

      assert_match(/not registered/, error.message)
    end

    def test_swarm_has_auto_generated_id
      swarm = Swarm.new(name: "Test Swarm")

      refute_nil(swarm.swarm_id)
      assert_match(/test_swarm_[a-f0-9]{8}/, swarm.swarm_id)
    end

    def test_swarm_accepts_explicit_id
      swarm = Swarm.new(name: "Test Swarm", swarm_id: "custom_id")

      assert_equal("custom_id", swarm.swarm_id)
    end

    def test_swarm_tracks_parent_swarm_id
      swarm = Swarm.new(name: "Child", swarm_id: "child", parent_swarm_id: "parent")

      assert_equal("parent", swarm.parent_swarm_id)
    end

    def test_swarm_has_delegation_call_stack
      swarm = Swarm.new(name: "Test")

      assert_empty(swarm.delegation_call_stack)
    end

    def test_swarm_override_swarm_ids
      swarm = Swarm.new(name: "Test", swarm_id: "original")

      swarm.override_swarm_ids(swarm_id: "new_id", parent_swarm_id: "parent")

      assert_equal("new_id", swarm.swarm_id)
      assert_equal("parent", swarm.parent_swarm_id)
    end

    def test_agent_context_includes_swarm_id
      context = Agent::Context.new(
        name: :backend,
        swarm_id: "test_swarm",
        parent_swarm_id: "parent_swarm",
      )

      assert_equal("test_swarm", context.swarm_id)
      assert_equal("parent_swarm", context.parent_swarm_id)
    end

    def test_agent_chat_has_clear_conversation_method
      # Verify that Agent::Chat has the clear_conversation method
      # The actual functionality is tested through swarm.reset_context! which calls it
      assert_includes(
        Agent::Chat.instance_methods,
        :clear_conversation,
        "Agent::Chat should have clear_conversation method",
      )
    end

    def test_swarm_reset_context_clears_all_agents
      # Use a simpler swarm without real LLM calls
      swarm = Swarm.new(name: "Test", swarm_id: "test")

      # Create chat instances with actual behavior
      backend_chat = Object.new
      frontend_chat = Object.new

      # Add clear_conversation method
      backend_cleared = false
      frontend_cleared = false

      backend_chat.define_singleton_method(:clear_conversation) { backend_cleared = true }
      frontend_chat.define_singleton_method(:clear_conversation) { frontend_cleared = true }

      # Set up agents hash
      swarm.instance_eval do
        @agents = { backend: backend_chat, frontend: frontend_chat }
      end

      # Reset context should call clear_conversation on both
      swarm.reset_context!

      assert(backend_cleared, "Expected backend agent to be cleared")
      assert(frontend_cleared, "Expected frontend agent to be cleared")
    end

    def test_delegate_tool_detects_circular_dependency
      swarm = Swarm.new(name: "Test", swarm_id: "test")

      # Create mock agent chat
      mock_chat = Minitest::Mock.new

      # Set up the delegation call stack on the swarm (simulating an existing delegation chain)
      swarm.delegation_call_stack.push("agent_a")
      swarm.delegation_call_stack.push("agent_b")

      tool = Tools::Delegate.new(
        delegate_name: "agent_a", # Try to delegate back to agent_a
        delegate_description: "Test agent",
        delegate_chat: mock_chat,
        agent_name: :agent_b,
        swarm: swarm,
      )

      # Execute should detect circular dependency
      result = tool.execute(message: "Do something")

      assert_match(/Circular delegation detected/, result)
      assert_match(/agent_a -> agent_b -> agent_a/, result)
    end

    def test_builder_requires_id_when_using_swarms
      error = assert_raises(ConfigurationError) do
        SwarmSDK.build do
          name("Test Swarm")
          lead(:backend)

          swarms do
            register("code_review", file: "./swarms/code_review.rb")
          end

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend dev")
            system("You build APIs")
          end
        end
      end

      assert_match(/id must be set/, error.message)
    end

    def test_builder_creates_swarm_with_explicit_id
      swarm = SwarmSDK.build do
        id("custom_id")
        name("Test Swarm")
        lead(:backend)

        agent(:backend) do
          model("gpt-4o-mini")
          description("Backend dev")
          system("You build APIs")
        end
      end

      assert_equal("custom_id", swarm.swarm_id)
    end

    def test_swarm_registry_builder_with_files
      builder = Swarm::SwarmRegistryBuilder.new

      builder.register("code_review", file: "./swarms/code_review.rb")
      builder.register("testing", file: "./swarms/testing.yml", keep_context: false)

      assert_equal(2, builder.registrations.size)

      reg1 = builder.registrations[0]

      assert_equal("code_review", reg1[:name])
      assert_equal(:file, reg1[:source][:type])
      assert_equal("./swarms/code_review.rb", reg1[:source][:value])
      assert(reg1[:keep_context])

      reg2 = builder.registrations[1]

      assert_equal("testing", reg2[:name])
      assert_equal(:file, reg2[:source][:type])
      assert_equal("./swarms/testing.yml", reg2[:source][:value])
      refute(reg2[:keep_context])
    end

    def test_swarm_registry_builder_with_yaml_string
      builder = Swarm::SwarmRegistryBuilder.new

      yaml_content = "version: 2\nswarm:\n  name: Test\n  lead: dev"
      builder.register("testing", yaml: yaml_content)

      assert_equal(1, builder.registrations.size)

      reg = builder.registrations[0]

      assert_equal("testing", reg[:name])
      assert_equal(:yaml, reg[:source][:type])
      assert_equal(yaml_content, reg[:source][:value])
      assert(reg[:keep_context])
    end

    def test_swarm_registry_builder_with_block
      builder = Swarm::SwarmRegistryBuilder.new

      builder.register("testing") do
        id("testing_team")
        name("Testing Team")
        lead(:tester)
      end

      assert_equal(1, builder.registrations.size)

      reg = builder.registrations[0]

      assert_equal("testing", reg[:name])
      assert_equal(:block, reg[:source][:type])
      assert_instance_of(Proc, reg[:source][:value])
      assert(reg[:keep_context])
    end

    def test_swarm_registry_builder_rejects_multiple_sources
      builder = Swarm::SwarmRegistryBuilder.new

      error = assert_raises(ArgumentError) do
        builder.register("testing", file: "./test.rb") do
          id("test")
        end
      end

      assert_match(/accepts only one of/, error.message)
    end

    def test_swarm_registry_builder_requires_source
      builder = Swarm::SwarmRegistryBuilder.new

      error = assert_raises(ArgumentError) do
        builder.register("testing")
      end

      assert_match(/requires either file:, yaml:, or a block/, error.message)
    end

    def test_configuration_loads_swarm_id_from_yaml
      yaml = <<~YAML
        version: 2
        swarm:
          id: custom_swarm_id
          name: "Test Swarm"
          lead: backend
          agents:
            backend:
              description: "Backend dev"
              model: gpt-4o-mini
              system: "You build APIs"
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      assert_equal("custom_swarm_id", config.swarm_id)
    end

    def test_configuration_loads_external_swarms_from_yaml_files
      yaml = <<~YAML
        version: 2
        swarm:
          id: main_swarm
          name: "Main Swarm"
          lead: backend
          swarms:
            code_review:
              file: "./swarms/code_review.rb"
              keep_context: true
            testing:
              file: "./swarms/testing.yml"
              keep_context: false
          agents:
            backend:
              description: "Backend dev"
              model: gpt-4o-mini
              system: "You build APIs"
              delegates_to:
                - code_review
                - testing
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      assert_equal(2, config.external_swarms.size)
      assert(config.external_swarms.key?(:code_review))
      assert(config.external_swarms.key?(:testing))

      assert_equal(:file, config.external_swarms[:code_review][:source][:type])
      assert_equal(:file, config.external_swarms[:testing][:source][:type])
      assert(config.external_swarms[:code_review][:keep_context])
      refute(config.external_swarms[:testing][:keep_context])
    end

    def test_configuration_loads_inline_swarm_definition_from_yaml
      yaml = <<~YAML
        version: 2
        swarm:
          id: main_swarm
          name: "Main Swarm"
          lead: backend
          swarms:
            testing:
              keep_context: false
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
          agents:
            backend:
              description: "Backend dev"
              model: gpt-4o-mini
              system: "You build APIs"
              delegates_to:
                - testing
      YAML

      config = Configuration.new(yaml)
      config.load_and_validate

      assert_equal(1, config.external_swarms.size)
      assert(config.external_swarms.key?(:testing))

      # Should be converted to YAML source type
      assert_equal(:yaml, config.external_swarms[:testing][:source][:type])
      refute(config.external_swarms[:testing][:keep_context])
    end

    private

    def create_test_swarm
      swarm = SwarmSDK.build do
        id("test_swarm")
        name("Test Swarm")
        lead(:backend)

        agent(:backend) do
          model("gpt-4o-mini")
          description("Backend developer")
          system("You build APIs")
          delegates_to(:frontend)
        end

        agent(:frontend) do
          model("gpt-4o-mini")
          description("Frontend developer")
          system("You build UIs")
        end
      end

      swarm
    end
  end
end
