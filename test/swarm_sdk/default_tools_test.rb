# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class DefaultToolsTest < Minitest::Test
    def setup
      # Set fake API keys to avoid RubyLLM configuration errors
      @original_anthropic_key = ENV["ANTHROPIC_API_KEY"]
      @original_openai_key = ENV["OPENAI_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "test-key-12345"
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure do |config|
        config.anthropic_api_key = "test-key-12345"
        config.openai_api_key = "test-key-12345"
      end
    end

    def teardown
      # Restore original API keys
      if @original_anthropic_key
        ENV["ANTHROPIC_API_KEY"] = @original_anthropic_key
      else
        ENV.delete("ANTHROPIC_API_KEY")
      end

      if @original_openai_key
        ENV["OPENAI_API_KEY"] = @original_openai_key
      else
        ENV.delete("OPENAI_API_KEY")
      end
    end

    def test_default_tools_constant
      expected_tools = [
        :Read,
        :Grep,
        :Glob,
      ]

      assert_equal(expected_tools, Swarm::DEFAULT_TOOLS)
    end

    def test_scratchpad_tools_constant
      expected_tools = [
        :ScratchpadWrite,
        :ScratchpadRead,
        :ScratchpadList,
      ]

      assert_equal(expected_tools, Swarm::ToolConfigurator::SCRATCHPAD_TOOLS)
    end

    # Memory tools are now provided via plugin system (not hardcoded constants)
    # Test removed - memory tools are in PluginRegistry, not ToolConfigurator

    def test_agent_includes_default_tools_by_default
      # Use non-persistent scratchpad for testing
      test_scratchpad = Tools::Stores::ScratchpadStorage.new
      swarm = Swarm.new(name: "Test Swarm", scratchpad: test_scratchpad)

      swarm.add_agent(create_agent(
        name: :developer,
        description: "Developer agent",
        model: "gpt-5",
        system_prompt: "You are a developer.",
        tools: [:Write], # Explicitly configured tool
      ))

      agent = swarm.agent(:developer)

      # Should have explicitly configured tools
      assert(agent.has_tool?(:Write), "Should have Write")

      # Should have all default tools
      assert(agent.has_tool?(:Read), "Should have default Read")
      assert(agent.has_tool?(:Grep), "Should have default Grep")
      assert(agent.has_tool?(:Glob), "Should have default Glob")
      assert(agent.has_tool?(:ScratchpadWrite), "Should have default ScratchpadWrite")
      assert(agent.has_tool?(:ScratchpadRead), "Should have default ScratchpadRead")
      assert(agent.has_tool?(:ScratchpadList), "Should have default ScratchpadList")
    end

    def test_agent_can_exclude_default_tools
      # Use non-persistent scratchpad for testing
      test_scratchpad = Tools::Stores::ScratchpadStorage.new
      swarm = Swarm.new(name: "Test Swarm", scratchpad: test_scratchpad)

      swarm.add_agent(create_agent(
        name: :developer,
        description: "Developer agent",
        model: "gpt-5",
        system_prompt: "You are a developer.",
        tools: [:Write, :Edit],
        disable_default_tools: true, # Disable defaults
      ))

      agent = swarm.agent(:developer)

      # Should have only explicitly configured tools
      assert(agent.has_tool?(:Write), "Should have Write")
      assert(agent.has_tool?(:Edit), "Should have Edit")

      # Should NOT have any default tools
      refute(agent.has_tool?(:Read), "Should NOT have Read")
      refute(agent.has_tool?(:Grep), "Should NOT have Grep")
      refute(agent.has_tool?(:ScratchpadWrite), "Should NOT have ScratchpadWrite")
    end

    def test_agent_with_no_tools_still_gets_defaults
      # Use non-persistent scratchpad for testing
      test_scratchpad = Tools::Stores::ScratchpadStorage.new
      swarm = Swarm.new(name: "Test Swarm", scratchpad: test_scratchpad)

      swarm.add_agent(create_agent(
        name: :developer,
        description: "Developer agent",
        model: "gpt-5",
        system_prompt: "You are a developer.",
        tools: [], # No explicit tools
      ))

      agent = swarm.agent(:developer)

      # Should have all default tools
      assert(agent.has_tool?(:Read), "Should have default Read")
      assert(agent.has_tool?(:Grep), "Should have default Grep")
      assert(agent.has_tool?(:ScratchpadWrite), "Should have default ScratchpadWrite")
    end

    def test_agent_with_no_tools_and_no_defaults_has_nothing
      # Use non-persistent scratchpad for testing
      test_scratchpad = Tools::Stores::ScratchpadStorage.new
      swarm = Swarm.new(name: "Test Swarm", scratchpad: test_scratchpad)

      swarm.add_agent(create_agent(
        name: :developer,
        description: "Developer agent",
        model: "gpt-5",
        system_prompt: "You are a developer.",
        tools: [],
        disable_default_tools: true,
      ))

      agent = swarm.agent(:developer)

      # Should have NO tools
      assert_empty(agent.tool_names, "Should have no tools")
    end

    def test_disable_specific_default_tools
      swarm = Swarm.new(name: "Test Swarm", scratchpad: Tools::Stores::ScratchpadStorage.new)

      swarm.add_agent(create_agent(
        name: :developer,
        description: "Developer agent",
        model: "gpt-5",
        system_prompt: "You are a developer.",
        tools: [:Write],
        disable_default_tools: [:Read, :Grep], # Disable only these
      ))

      agent = swarm.agent(:developer)

      # Should NOT have disabled tools
      refute(agent.has_tool?(:Read), "Should NOT have Read")
      refute(agent.has_tool?(:Grep), "Should NOT have Grep")

      # Should have other default tools
      assert(agent.has_tool?(:Glob), "Should have Glob")
      assert(agent.has_tool?(:ScratchpadWrite), "Should have ScratchpadWrite")

      # Should have explicit tool
      assert(agent.has_tool?(:Write), "Should have Write")
    end

    def test_disable_default_tools_via_dsl_true
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          model("gpt-5")
          system_prompt("Test")
          tools(:Write)
          disable_default_tools(true) # Disable all
        end
      end

      agent_chat = swarm.agent(:agent1)

      # Should NOT have any default tools
      refute(agent_chat.has_tool?(:Read), "Should NOT have Read")
      refute(agent_chat.has_tool?(:Grep), "Should NOT have Grep")
      refute(agent_chat.has_tool?(:Glob), "Should NOT have Glob")

      # Should have explicit tool
      assert(agent_chat.has_tool?(:Write), "Should have Write")
    end

    def test_disable_default_tools_via_dsl_array
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          model("gpt-5")
          system_prompt("Test")
          disable_default_tools([:Read, :Grep]) # Disable specific tools
        end
      end

      agent_chat = swarm.agent(:agent1)

      # Should NOT have disabled tools
      refute(agent_chat.has_tool?(:Read), "Should NOT have Read")
      refute(agent_chat.has_tool?(:Grep), "Should NOT have Grep")

      # Should have other default tools
      assert(agent_chat.has_tool?(:Glob), "Should have Glob")
    end

    def test_disable_default_tools_via_dsl_single_symbol
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          model("gpt-5")
          system_prompt("Test")
          disable_default_tools(:Read) # Disable single tool via symbol
        end
      end

      agent_chat = swarm.agent(:agent1)

      # Should NOT have disabled tool
      refute(agent_chat.has_tool?(:Read), "Should NOT have Read")

      # Should have other default tools
      assert(agent_chat.has_tool?(:Grep), "Should have Grep")
      assert(agent_chat.has_tool?(:Glob), "Should have Glob")
    end

    def test_disable_default_tools_via_dsl_varargs
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          model("gpt-5")
          system_prompt("Test")
          disable_default_tools(:Read, :Grep) # Multiple args
        end
      end

      agent_chat = swarm.agent(:agent1)

      # Should NOT have disabled tools
      refute(agent_chat.has_tool?(:Read), "Should NOT have Read")
      refute(agent_chat.has_tool?(:Grep), "Should NOT have Grep")

      # Should have other default tools
      assert(agent_chat.has_tool?(:Glob), "Should have Glob")
    end
  end
end
