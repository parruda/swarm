# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class AgentRegistryTest < Minitest::Test
    def setup
      # Reset SwarmSDK config to ensure fresh state
      SwarmSDK.reset_config!

      # Clear the agent registry before each test
      SwarmSDK.clear_agent_registry!

      # Set fake API key to avoid configuration errors
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"

      # Configure SwarmSDK
      SwarmSDK.configure do |config|
        config.openai_api_key = "test-key-12345"
      end
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key

      # Reset SwarmSDK config and agent registry
      SwarmSDK.reset_config!
      SwarmSDK.clear_agent_registry!
    end

    # =========================================================================
    # AgentRegistry Class Tests
    # =========================================================================

    def test_register_stores_block
      AgentRegistry.register(:backend) do
        model("claude-sonnet-4")
        description("Test backend")
      end

      assert(AgentRegistry.registered?(:backend))
    end

    def test_register_requires_block
      error = assert_raises(ArgumentError) do
        AgentRegistry.register(:backend)
      end

      assert_equal("Block required for agent registration", error.message)
    end

    def test_register_converts_string_names_to_symbols
      AgentRegistry.register("frontend") do
        description("Test frontend")
      end

      assert(AgentRegistry.registered?(:frontend))
      assert(AgentRegistry.registered?("frontend"))
    end

    def test_get_returns_registered_block
      registered_block = proc do
        model("gpt-5")
        description("Test")
      end

      AgentRegistry.register(:tester, &registered_block)
      retrieved = AgentRegistry.get(:tester)

      assert_equal(registered_block, retrieved)
    end

    def test_get_returns_nil_for_unregistered
      result = AgentRegistry.get(:nonexistent)

      assert_nil(result)
    end

    def test_registered_returns_true_for_registered
      AgentRegistry.register(:worker) { description("Worker") }

      assert(AgentRegistry.registered?(:worker))
    end

    def test_registered_returns_false_for_unregistered
      refute(AgentRegistry.registered?(:missing))
    end

    def test_names_returns_all_registered_names
      AgentRegistry.register(:alpha) { description("Alpha") }
      AgentRegistry.register(:beta) { description("Beta") }
      AgentRegistry.register(:gamma) { description("Gamma") }

      names = AgentRegistry.names

      assert_equal(3, names.size)
      assert_includes(names, :alpha)
      assert_includes(names, :beta)
      assert_includes(names, :gamma)
    end

    def test_names_returns_empty_array_when_none_registered
      assert_empty(AgentRegistry.names)
    end

    def test_clear_removes_all_registrations
      AgentRegistry.register(:one) { description("One") }
      AgentRegistry.register(:two) { description("Two") }

      AgentRegistry.clear

      refute(AgentRegistry.registered?(:one))
      refute(AgentRegistry.registered?(:two))
      assert_empty(AgentRegistry.names)
    end

    # =========================================================================
    # SwarmSDK Module Method Tests
    # =========================================================================

    def test_swarm_sdk_agent_delegates_to_registry
      SwarmSDK.agent(:coordinator) do
        model("claude-sonnet-4")
        description("Coordinator agent")
      end

      assert(AgentRegistry.registered?(:coordinator))
    end

    def test_swarm_sdk_clear_agent_registry_clears_all
      SwarmSDK.agent(:temp_agent) do
        description("Temporary")
      end

      SwarmSDK.clear_agent_registry!

      refute(AgentRegistry.registered?(:temp_agent))
    end

    # =========================================================================
    # Registry Lookup in Swarm Builder Tests
    # =========================================================================

    def test_agent_lookup_from_registry
      # Register agent globally
      SwarmSDK.agent(:backend) do
        model("claude-sonnet-4")
        description("Backend developer")
        system_prompt("You build APIs")
        tools(:Read, :Write)
      end

      # Build swarm using registry lookup
      swarm = SwarmSDK.build do
        name("Test Team")
        lead(:backend)

        agent(:backend) # Should fetch from registry
      end

      # Verify agent was created correctly
      assert_includes(swarm.agent_names, :backend)

      # Get the agent definition
      definition = swarm.agent_definition(:backend)

      assert_equal("claude-sonnet-4", definition.model)
      assert_equal("Backend developer", definition.description)
      assert_includes(definition.system_prompt, "You build APIs")
    end

    def test_agent_lookup_raises_when_not_registered
      error = assert_raises(ConfigurationError) do
        SwarmSDK.build do
          name("Test Team")
          lead(:missing)

          agent(:missing) # Not registered, should raise
        end
      end

      assert_match(/Agent 'missing' not found in registry/, error.message)
      assert_match(/define inline.*or.*register globally/, error.message)
    end

    # =========================================================================
    # Registry + Overrides Tests
    # =========================================================================

    def test_agent_registry_with_overrides_adds_tools
      # Register base agent
      SwarmSDK.agent(:api_builder) do
        model("gpt-5")
        description("API builder")
        tools(:Read)
      end

      # Build swarm with overrides
      swarm = SwarmSDK.build do
        name("Extended Team")
        lead(:api_builder)

        agent(:api_builder) do
          # Override adds to base
          tools(:Write, :Edit)
        end
      end

      definition = swarm.agent_definition(:api_builder)
      tool_names = definition.tools.map { |t| t[:name] }

      # Should have both base and override tools
      assert_includes(tool_names, :Read)
      assert_includes(tool_names, :Write)
      assert_includes(tool_names, :Edit)
    end

    def test_agent_registry_with_overrides_changes_model
      SwarmSDK.agent(:flexible) do
        model("gpt-5")
        description("Flexible agent")
      end

      swarm = SwarmSDK.build do
        name("Override Team")
        lead(:flexible)

        agent(:flexible) do
          model("claude-sonnet-4") # Override the model
        end
      end

      definition = swarm.agent_definition(:flexible)

      assert_equal("claude-sonnet-4", definition.model)
    end

    def test_agent_registry_with_overrides_adds_delegates_to
      SwarmSDK.agent(:lead_agent) do
        description("Lead agent")
      end

      SwarmSDK.agent(:helper_agent) do
        description("Helper agent")
      end

      swarm = SwarmSDK.build do
        name("Delegation Team")
        lead(:lead_agent)

        agent(:lead_agent) do
          delegates_to(:helper_agent)
        end

        agent(:helper_agent)
      end

      definition = swarm.agent_definition(:lead_agent)

      assert_includes(definition.delegates_to, :helper_agent)
    end

    # =========================================================================
    # Inline DSL Still Works (Not in Registry)
    # =========================================================================

    def test_inline_dsl_works_when_not_registered
      # Don't register :custom - use inline DSL
      swarm = SwarmSDK.build do
        name("Inline Team")
        lead(:custom)

        agent(:custom) do
          model("claude-sonnet-4")
          description("Custom agent")
          system_prompt("You are custom")
        end
      end

      assert_includes(swarm.agent_names, :custom)
      definition = swarm.agent_definition(:custom)

      assert_equal("claude-sonnet-4", definition.model)
    end

    def test_registry_takes_precedence_when_registered_and_block_given
      # Register with one model
      SwarmSDK.agent(:configurable) do
        model("gpt-5")
        description("Base config")
        tools(:Read)
      end

      # When block is given and agent is registered,
      # registry config is applied first, then block
      swarm = SwarmSDK.build do
        name("Priority Team")
        lead(:configurable)

        agent(:configurable) do
          # This should extend, not replace
          tools(:Write)
        end
      end

      definition = swarm.agent_definition(:configurable)
      tool_names = definition.tools.map { |t| t[:name] }

      # Should have BOTH Read (from registry) and Write (from override)
      assert_includes(tool_names, :Read)
      assert_includes(tool_names, :Write)
    end

    # =========================================================================
    # Multiple Swarms Using Same Registry
    # =========================================================================

    def test_multiple_swarms_share_registry
      SwarmSDK.agent(:shared_agent) do
        model("claude-sonnet-4")
        description("Shared across swarms")
      end

      swarm1 = SwarmSDK.build do
        name("Team 1")
        lead(:shared_agent)
        agent(:shared_agent)
      end

      swarm2 = SwarmSDK.build do
        name("Team 2")
        lead(:shared_agent)
        agent(:shared_agent)
      end

      # Both swarms should have the agent
      assert_includes(swarm1.agent_names, :shared_agent)
      assert_includes(swarm2.agent_names, :shared_agent)

      # Definitions should be equivalent
      def1 = swarm1.agent_definition(:shared_agent)
      def2 = swarm2.agent_definition(:shared_agent)

      assert_equal(def1.model, def2.model)
      assert_equal(def1.description, def2.description)
    end

    def test_different_overrides_in_different_swarms
      SwarmSDK.agent(:base_agent) do
        model("gpt-5")
        description("Base agent")
      end

      swarm1 = SwarmSDK.build do
        name("Team 1")
        lead(:base_agent)
        agent(:base_agent) do
          tools(:Read)
        end
      end

      swarm2 = SwarmSDK.build do
        name("Team 2")
        lead(:base_agent)
        agent(:base_agent) do
          tools(:Write)
        end
      end

      def1 = swarm1.agent_definition(:base_agent)
      def2 = swarm2.agent_definition(:base_agent)

      tool_names1 = def1.tools.map { |t| t[:name] }
      tool_names2 = def2.tools.map { |t| t[:name] }

      assert_includes(tool_names1, :Read)
      refute_includes(tool_names1, :Write)

      assert_includes(tool_names2, :Write)
      refute_includes(tool_names2, :Read)
    end

    # =========================================================================
    # Workflow Builder Support
    # =========================================================================

    def test_workflow_builder_supports_registry
      SwarmSDK.agent(:node_agent) do
        model("claude-sonnet-4")
        description("Workflow node agent")
      end

      workflow = SwarmSDK.workflow do
        name("Test Workflow")
        start_node(:step1)

        agent(:node_agent) # From registry

        node(:step1) do
          agent(:node_agent)
        end
      end

      assert_includes(workflow.agent_definitions.keys, :node_agent)
    end

    # =========================================================================
    # Workflow Node Registry Fallback Tests
    # =========================================================================

    def test_workflow_node_agent_auto_resolves_from_registry
      # Register agent globally - don't define at workflow level
      SwarmSDK.agent(:global_analyzer) do
        model("claude-sonnet-4")
        description("Global analyzer agent")
      end

      # Build workflow without explicitly defining the agent
      workflow = SwarmSDK.workflow do
        name("Auto Resolve Workflow")
        start_node(:analyze)

        # NO agent definition here - should auto-resolve from registry

        node(:analyze) do
          agent(:global_analyzer)
        end
      end

      # Agent should be present even though not defined at workflow level
      assert_includes(workflow.agent_definitions.keys, :global_analyzer)

      definition = workflow.agent_definitions[:global_analyzer]

      assert_equal("claude-sonnet-4", definition.model)
      assert_equal("Global analyzer agent", definition.description)
    end

    def test_workflow_node_agent_prefers_workflow_definition_over_registry
      # Register agent globally
      SwarmSDK.agent(:configurable_agent) do
        model("gpt-3")
        description("Global version")
      end

      # Build workflow WITH explicit agent definition
      workflow = SwarmSDK.workflow do
        name("Override Workflow")
        start_node(:process)

        # Define at workflow level - should take precedence
        agent(:configurable_agent) do
          model("claude-sonnet-4")
          description("Workflow version")
        end

        node(:process) do
          agent(:configurable_agent)
        end
      end

      # Workflow definition should win
      definition = workflow.agent_definitions[:configurable_agent]

      assert_equal("claude-sonnet-4", definition.model)
      assert_equal("Workflow version", definition.description)
    end

    def test_workflow_node_agent_raises_when_not_found_anywhere
      error = assert_raises(ConfigurationError) do
        SwarmSDK.workflow do
          name("Missing Agent Workflow")
          start_node(:step1)

          node(:step1) do
            agent(:nonexistent_agent)
          end
        end
      end

      assert_match(/Agent 'nonexistent_agent' referenced in node but not found/, error.message)
      assert_match(/define at workflow level/, error.message)
      assert_match(/register globally/, error.message)
    end

    def test_workflow_multiple_nodes_resolve_different_agents_from_registry
      SwarmSDK.agent(:planner_agent) do
        model("gpt-4")
        description("Plans things")
      end

      SwarmSDK.agent(:executor_agent) do
        model("claude-sonnet-4")
        description("Executes things")
      end

      workflow = SwarmSDK.workflow do
        name("Multi-Registry Workflow")
        start_node(:planning)

        node(:planning) do
          agent(:planner_agent)
        end

        node(:execution) do
          agent(:executor_agent)
          depends_on(:planning)
        end
      end

      # Both agents should be resolved from registry
      assert_includes(workflow.agent_definitions.keys, :planner_agent)
      assert_includes(workflow.agent_definitions.keys, :executor_agent)

      assert_equal("gpt-4", workflow.agent_definitions[:planner_agent].model)
      assert_equal("claude-sonnet-4", workflow.agent_definitions[:executor_agent].model)
    end

    def test_workflow_mixed_defined_and_registry_agents
      SwarmSDK.agent(:registry_agent) do
        model("gpt-5")
        description("From registry")
      end

      workflow = SwarmSDK.workflow do
        name("Mixed Workflow")
        start_node(:step1)

        # Define one agent at workflow level
        agent(:workflow_agent) do
          model("claude-sonnet-4")
          description("Defined in workflow")
        end

        node(:step1) do
          agent(:workflow_agent).delegates_to(:registry_agent)
        end
      end

      # Both should be present
      assert_includes(workflow.agent_definitions.keys, :workflow_agent)
      assert_includes(workflow.agent_definitions.keys, :registry_agent)

      assert_equal("Defined in workflow", workflow.agent_definitions[:workflow_agent].description)
      assert_equal("From registry", workflow.agent_definitions[:registry_agent].description)
    end

    def test_workflow_node_delegates_to_auto_resolves_from_registry
      SwarmSDK.agent(:main_agent) do
        model("gpt-4")
        description("Main agent")
      end

      SwarmSDK.agent(:helper_agent) do
        model("gpt-3")
        description("Helper agent")
      end

      workflow = SwarmSDK.workflow do
        name("Delegation Workflow")
        start_node(:process)

        node(:process) do
          agent(:main_agent).delegates_to(:helper_agent)
        end
      end

      # Both main and delegate should be resolved from registry
      assert_includes(workflow.agent_definitions.keys, :main_agent)
      assert_includes(workflow.agent_definitions.keys, :helper_agent)
    end

    # =========================================================================
    # Mixed Usage Tests
    # =========================================================================

    def test_mixed_registry_inline_and_markdown
      SwarmSDK.agent(:from_registry) do
        model("gpt-5")
        description("From registry")
      end

      markdown_content = <<~MD
        ---
        description: "From markdown"
        model: "claude-sonnet-4"
        ---

        You are from markdown.
      MD

      swarm = SwarmSDK.build do
        name("Mixed Team")
        lead(:from_registry)

        agent(:from_registry) # Registry
        agent(:from_inline) do
          description("From inline")
          model("gpt-4")
        end
        agent(:from_markdown, markdown_content)
      end

      assert_includes(swarm.agent_names, :from_registry)
      assert_includes(swarm.agent_names, :from_inline)
      assert_includes(swarm.agent_names, :from_markdown)

      assert_equal("gpt-5", swarm.agent_definition(:from_registry).model)
      assert_equal("gpt-4", swarm.agent_definition(:from_inline).model)
      assert_equal("claude-sonnet-4", swarm.agent_definition(:from_markdown).model)
    end

    # =========================================================================
    # Edge Cases
    # =========================================================================

    def test_duplicate_registration_raises_error
      SwarmSDK.agent(:unique_agent) do
        model("gpt-3")
        description("First version")
      end

      # Trying to register again should raise
      error = assert_raises(ArgumentError) do
        SwarmSDK.agent(:unique_agent) do
          model("gpt-5")
          description("Second version")
        end
      end

      assert_match(/Agent 'unique_agent' is already registered/, error.message)
      assert_match(/clear_agent_registry!/, error.message)
    end

    def test_can_reregister_after_clear
      SwarmSDK.agent(:clearable) do
        model("gpt-3")
        description("First version")
      end

      # Clear the registry
      SwarmSDK.clear_agent_registry!

      # Now we can register again
      SwarmSDK.agent(:clearable) do
        model("gpt-5")
        description("Second version")
      end

      swarm = SwarmSDK.build do
        name("Reregister Test")
        lead(:clearable)
        agent(:clearable)
      end

      definition = swarm.agent_definition(:clearable)

      assert_equal("gpt-5", definition.model)
      assert_equal("Second version", definition.description)
    end

    def test_registry_with_all_agents_config
      SwarmSDK.agent(:team_member) do
        description("Team member")
        tools(:Read)
      end

      swarm = SwarmSDK.build do
        name("All Agents Test")
        lead(:team_member)

        all_agents do
          model("claude-sonnet-4")
          tools(:Glob)
        end

        agent(:team_member) # From registry
      end

      definition = swarm.agent_definition(:team_member)

      # Model from all_agents (since registry didn't override model_set?)
      # Actually, the registry block sets no model, so default is used
      # all_agents should apply its model
      assert_equal("claude-sonnet-4", definition.model)

      # Tools should include both registry and all_agents
      tool_names = definition.tools.map { |t| t[:name] }

      assert_includes(tool_names, :Read)
      assert_includes(tool_names, :Glob)
    end

    # =========================================================================
    # Additional Edge Cases
    # =========================================================================

    def test_system_prompt_override_from_registry
      SwarmSDK.agent(:promptable) do
        model("gpt-4")
        description("Promptable agent")
        system_prompt("Base system prompt from registry")
      end

      swarm = SwarmSDK.build do
        name("Prompt Override Test")
        lead(:promptable)

        agent(:promptable) do
          system_prompt("Extended system prompt") # Override
        end
      end

      definition = swarm.agent_definition(:promptable)

      # System prompt should contain the override (SDK may add prefix)
      assert_includes(definition.system_prompt, "Extended system prompt")
      # Should NOT contain the base prompt
      refute_includes(definition.system_prompt, "Base system prompt from registry")
    end

    def test_system_prompt_preserved_when_not_overridden
      SwarmSDK.agent(:keeper) do
        model("gpt-4")
        description("Prompt keeper")
        system_prompt("Original prompt that should be kept")
      end

      swarm = SwarmSDK.build do
        name("Prompt Keep Test")
        lead(:keeper)

        agent(:keeper) do
          tools(:Read) # Add tools but don't touch system_prompt
        end
      end

      definition = swarm.agent_definition(:keeper)

      # Original system prompt should be preserved (SDK may add prefix)
      assert_includes(definition.system_prompt, "Original prompt that should be kept")
    end

    def test_swarm_lead_purely_from_registry
      # Register lead agent - don't define at swarm level
      SwarmSDK.agent(:registry_lead) do
        model("claude-sonnet-4")
        description("Lead from registry")
        system_prompt("I am the lead")
      end

      SwarmSDK.agent(:registry_helper) do
        model("gpt-3")
        description("Helper from registry")
      end

      # Build swarm using only registry agents
      swarm = SwarmSDK.build do
        name("Registry Only Team")
        lead(:registry_lead)

        agent(:registry_lead)
        agent(:registry_helper)
      end

      # Verify lead is set correctly
      assert_equal(:registry_lead, swarm.lead_agent)
      assert_includes(swarm.agent_names, :registry_lead)
      assert_includes(swarm.agent_names, :registry_helper)
    end

    def test_filesystem_tools_validation_for_registry_agents
      SwarmSDK.agent(:filesystem_agent) do
        model("gpt-4")
        description("Uses filesystem")
        tools(:Read, :Write, :Edit)
      end

      # When filesystem tools are disabled, should raise
      SwarmSDK.configure { |c| c.allow_filesystem_tools = false }

      error = assert_raises(ConfigurationError) do
        SwarmSDK.build do
          name("Filesystem Test")
          lead(:filesystem_agent)
          agent(:filesystem_agent)
        end
      end

      assert_match(/Filesystem tools are globally disabled/, error.message)
    ensure
      SwarmSDK.configure { |c| c.allow_filesystem_tools = true }
    end

    def test_workflow_all_agents_applies_to_auto_resolved_registry_agents
      SwarmSDK.agent(:workflow_member) do
        description("Workflow member")
        tools(:Read)
      end

      workflow = SwarmSDK.workflow do
        name("All Agents Workflow")
        start_node(:work)

        all_agents do
          model("claude-sonnet-4")
          tools(:Glob)
        end

        # Don't define agent at workflow level - auto-resolve from registry
        node(:work) do
          agent(:workflow_member)
        end
      end

      definition = workflow.agent_definitions[:workflow_member]

      # Model from all_agents (registry didn't set model)
      assert_equal("claude-sonnet-4", definition.model)

      # Tools should include both registry and all_agents
      tool_names = definition.tools.map { |t| t[:name] }

      assert_includes(tool_names, :Read)
      assert_includes(tool_names, :Glob)
    end

    def test_empty_block_override_preserves_registry_config
      SwarmSDK.agent(:complete_agent) do
        model("gpt-5")
        description("Complete agent")
        system_prompt("Complete prompt content")
        tools(:Read, :Write)
      end

      swarm = SwarmSDK.build do
        name("Empty Override Test")
        lead(:complete_agent)

        # Empty block - should preserve all registry config
        agent(:complete_agent) do
          # intentionally empty
        end
      end

      definition = swarm.agent_definition(:complete_agent)

      # All config should be preserved
      assert_equal("gpt-5", definition.model)
      assert_equal("Complete agent", definition.description)
      # System prompt preserved (SDK may add prefix)
      assert_includes(definition.system_prompt, "Complete prompt content")

      tool_names = definition.tools.map { |t| t[:name] }

      assert_includes(tool_names, :Read)
      assert_includes(tool_names, :Write)
    end

    def test_provider_and_base_url_in_registry
      SwarmSDK.agent(:custom_provider_agent) do
        model("custom-model")
        provider(:openai)
        base_url("https://custom.api.example.com")
        description("Custom provider agent")
      end

      swarm = SwarmSDK.build do
        name("Custom Provider Test")
        lead(:custom_provider_agent)
        agent(:custom_provider_agent)
      end

      definition = swarm.agent_definition(:custom_provider_agent)

      assert_equal("custom-model", definition.model)
      assert_equal(:openai, definition.provider)
      assert_equal("https://custom.api.example.com", definition.base_url)
    end

    def test_registry_agent_with_predefined_delegates_to
      SwarmSDK.agent(:delegating_agent) do
        model("gpt-4")
        description("Agent that delegates")
        delegates_to(:helper_one, :helper_two)
      end

      SwarmSDK.agent(:helper_one) do
        model("gpt-3")
        description("Helper one")
      end

      SwarmSDK.agent(:helper_two) do
        model("gpt-3")
        description("Helper two")
      end

      swarm = SwarmSDK.build do
        name("Predefined Delegation Test")
        lead(:delegating_agent)

        agent(:delegating_agent)
        agent(:helper_one)
        agent(:helper_two)
      end

      definition = swarm.agent_definition(:delegating_agent)

      assert_includes(definition.delegates_to, :helper_one)
      assert_includes(definition.delegates_to, :helper_two)
    end

    def test_registry_delegates_to_can_be_extended
      SwarmSDK.agent(:extendable_delegator) do
        model("gpt-4")
        description("Extendable delegator")
        delegates_to(:base_helper)
      end

      SwarmSDK.agent(:base_helper) do
        description("Base helper")
      end

      SwarmSDK.agent(:extra_helper) do
        description("Extra helper")
      end

      swarm = SwarmSDK.build do
        name("Extended Delegation Test")
        lead(:extendable_delegator)

        agent(:extendable_delegator) do
          delegates_to(:extra_helper) # Adds to existing
        end
        agent(:base_helper)
        agent(:extra_helper)
      end

      definition = swarm.agent_definition(:extendable_delegator)

      # Should have both base and extended delegates
      assert_includes(definition.delegates_to, :base_helper)
      assert_includes(definition.delegates_to, :extra_helper)
    end

    def test_coding_agent_flag_in_registry
      SwarmSDK.agent(:coding_enabled) do
        model("gpt-4")
        description("Coding enabled agent")
        coding_agent(true)
      end

      SwarmSDK.agent(:coding_disabled) do
        model("gpt-4")
        description("Coding disabled agent")
        coding_agent(false)
      end

      swarm = SwarmSDK.build do
        name("Coding Agent Test")
        lead(:coding_enabled)

        agent(:coding_enabled)
        agent(:coding_disabled)
      end

      enabled_def = swarm.agent_definition(:coding_enabled)
      disabled_def = swarm.agent_definition(:coding_disabled)

      assert(enabled_def.coding_agent)
      refute(disabled_def.coding_agent)
    end

    def test_timeout_and_context_window_in_registry
      SwarmSDK.agent(:tuned_agent) do
        model("gpt-4")
        description("Tuned agent")
        timeout(120)
        context_window(32_000)
      end

      swarm = SwarmSDK.build do
        name("Tuned Agent Test")
        lead(:tuned_agent)
        agent(:tuned_agent)
      end

      definition = swarm.agent_definition(:tuned_agent)

      assert_equal(120, definition.timeout)
      assert_equal(32_000, definition.context_window)
    end

    def test_parameters_and_headers_in_registry
      SwarmSDK.agent(:parameterized_agent) do
        model("gpt-4")
        description("Parameterized agent")
        parameters(temperature: 0.7, max_tokens: 4000)
        headers("X-Custom-Header" => "custom-value")
      end

      swarm = SwarmSDK.build do
        name("Parameters Test")
        lead(:parameterized_agent)
        agent(:parameterized_agent)
      end

      definition = swarm.agent_definition(:parameterized_agent)

      assert_in_delta(0.7, definition.parameters[:temperature])
      assert_equal(4000, definition.parameters[:max_tokens])
      assert_equal("custom-value", definition.headers["X-Custom-Header"])
    end

    def test_directory_setting_in_registry
      test_dir = Dir.pwd

      SwarmSDK.agent(:directory_agent) do
        model("gpt-4")
        description("Directory agent")
        directory(test_dir)
      end

      swarm = SwarmSDK.build do
        name("Directory Test")
        lead(:directory_agent)
        agent(:directory_agent)
      end

      definition = swarm.agent_definition(:directory_agent)

      assert_equal(test_dir, definition.directory)
    end

    def test_workflow_agent_less_node_with_registry_agents
      # Agent-less nodes shouldn't break even when registry agents exist
      SwarmSDK.agent(:some_agent) do
        model("gpt-4")
        description("Some agent")
      end

      workflow = SwarmSDK.workflow do
        name("Agent-less Node Test")
        start_node(:compute)

        agent(:some_agent)

        # Agent-less node with just transformer
        node(:compute) do
          input { |ctx| "transformed: #{ctx.content}" }
        end

        node(:process) do
          agent(:some_agent)
          depends_on(:compute)
        end
      end

      # Should build successfully
      assert_includes(workflow.agent_definitions.keys, :some_agent)
      assert_predicate(workflow.nodes[:compute], :agent_less?)
    end

    def test_same_agent_in_multiple_workflow_nodes_from_registry
      SwarmSDK.agent(:reusable_agent) do
        model("claude-sonnet-4")
        description("Reusable across nodes")
      end

      workflow = SwarmSDK.workflow do
        name("Reuse Agent Workflow")
        start_node(:first)

        node(:first) do
          agent(:reusable_agent)
        end

        node(:second) do
          agent(:reusable_agent)
          depends_on(:first)
        end

        node(:third) do
          agent(:reusable_agent)
          depends_on(:second)
        end
      end

      # Should only have one definition even though used in 3 nodes
      assert_equal(1, workflow.agent_definitions.size)
      assert_includes(workflow.agent_definitions.keys, :reusable_agent)
    end
  end
end
