# frozen_string_literal: true

require_relative "../../swarm_memory_test_helper"
require "tmpdir"

# Integration test for Skills feature with SwarmSDK
class SkillsIntegrationTest < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("skills-integration-test")
    @memory_dir = File.join(@temp_dir, ".memory")

    # Set fake API key for RubyLLM
    @original_api_key = ENV["OPENAI_API_KEY"]
    ENV["OPENAI_API_KEY"] = "test-key-12345"
    RubyLLM.configure { |config| config.openai_api_key = "test-key-12345" }
  end

  def teardown
    FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
    ENV["OPENAI_API_KEY"] = @original_api_key
    RubyLLM.configure { |config| config.openai_api_key = @original_api_key }
  end

  def test_agent_with_memory_gets_all_memory_tools_including_load_skill
    # Create a swarm with memory-enabled agent
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:test_agent)

      agent(:test_agent) do
        description("Test agent with memory")
        coding_agent(false)
        # Remove disable_default_tools - let memory plugin tools be registered
        tools(:Read, :Write)
        directory(temp_dir)

        memory do
          adapter(:filesystem)
          directory(memory_dir)
          mode(:full_access) # All tools available
        end
      end
    end

    # Get the agent
    agent = swarm.agent(:test_agent)

    # Check that memory tools are present
    tool_names = agent.tools.values.map(&:name)

    assert_includes(tool_names, "MemoryWrite")
    assert_includes(tool_names, "MemoryRead")
    assert_includes(tool_names, "MemoryEdit")
    assert_includes(tool_names, "MemoryGlob")
    assert_includes(tool_names, "MemoryGrep")
    assert_includes(tool_names, "MemoryDelete")
    assert_includes(tool_names, "MemoryDefrag")
    assert_includes(tool_names, "LoadSkill")

    # Check explicit tools are still present
    assert_includes(tool_names, "Read")
    assert_includes(tool_names, "Write")
  end

  def test_agent_without_memory_does_not_get_load_skill
    # Create a swarm without memory
    temp_dir = @temp_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:test_agent)

      agent(:test_agent) do
        description("Test agent without memory")
        coding_agent(false)
        disable_default_tools(true)
        tools(:Read, :Write)
        directory(temp_dir)
      end
    end

    agent = swarm.agent(:test_agent)
    tool_names = agent.tools.values.map(&:name)

    # Should not have memory tools
    refute_includes(tool_names, "MemoryWrite")
    refute_includes(tool_names, "MemoryRead")
    refute_includes(tool_names, "LoadSkill")

    # Should have explicit tools
    assert_includes(tool_names, "Read")
    assert_includes(tool_names, "Write")
  end

  def test_memory_tools_are_present_when_memory_enabled
    # Create a swarm with memory
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:test_agent)

      agent(:test_agent) do
        description("Test agent")
        coding_agent(false)
        # Remove disable_default_tools - let memory plugin tools be registered
        tools(:Read)
        directory(temp_dir)

        memory do
          directory(memory_dir)
          mode(:full_access) # All tools available
        end
      end
    end

    agent = swarm.agent(:test_agent)

    # Check that all memory tools are present
    tool_names = agent.tools.values.map(&:name)
    expected_memory_tools = [
      "MemoryWrite",
      "MemoryRead",
      "MemoryEdit",
      "MemoryDelete",
      "MemoryGlob",
      "MemoryGrep",
      "MemoryDefrag",
      "LoadSkill",
    ]

    expected_memory_tools.each do |tool_name|
      assert_includes(tool_names, tool_name)
    end
  end

  def test_memory_read_returns_json_for_skills
    # Create swarm with memory
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:test_agent)

      agent(:test_agent) do
        description("Test agent")
        coding_agent(false)
        directory(temp_dir)

        memory do
          directory(memory_dir)
        end
      end
    end

    agent = swarm.agent(:test_agent)

    # Write a skill using MemoryWrite (with ALL required fields)
    memory_write = agent.tools.values.find { |t| t.name == "MemoryWrite" }
    memory_write.execute(
      file_path: "skill/test-skill.md",
      content: "# Test Skill\n\nStep by step instructions",
      title: "Test Skill",
      type: "skill",
      confidence: "high",
      tags: ["testing", "skill"],
      related: [],
      domain: "testing",
      source: "experimentation",
      tools: ["Read", "Edit"],
      permissions: { "Edit" => { "allowed_paths" => ["tmp/**"] } },
    )

    # Read it back using MemoryRead
    memory_read = agent.tools.values.find { |t| t.name == "MemoryRead" }
    result = memory_read.execute(file_path: "skill/test-skill.md")

    # Should return raw plain text
    assert_equal("# Test Skill\n\nStep by step instructions", result)
  end

  def test_swarm_sdk_works_without_swarm_memory_gem
    # This test verifies SwarmSDK doesn't break when memory is not configured
    # The dynamic immutable tools list should work fine with just ["Think", "Clock"]
    temp_dir = @temp_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:test_agent)

      agent(:test_agent) do
        description("Test agent")
        coding_agent(false)
        disable_default_tools(true)
        tools(:Read, :Write)
        directory(temp_dir)
      end
    end

    agent = swarm.agent(:test_agent)

    # Should have explicit tools only (disable_default_tools removes default tools)
    tool_names = agent.tools.values.map(&:name)

    assert_includes(tool_names, "Read")
    assert_includes(tool_names, "Write")

    # Should not have default tools (disabled)
    refute_includes(tool_names, "Think")
    refute_includes(tool_names, "TodoWrite")
    refute_includes(tool_names, "Grep")

    # Should not have memory tools
    refute_includes(tool_names, "MemoryWrite")
    refute_includes(tool_names, "LoadSkill")

    # Should not crash
    assert(agent)
  end
end
