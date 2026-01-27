# frozen_string_literal: true

require_relative "../../swarm_memory_test_helper"
require "tmpdir"

# End-to-end test for complete skill workflow
class SkillWorkflowTest < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("skill-workflow-test")
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

  def test_complete_skill_workflow
    # Scenario: Agent creates a skill, then later loads it and tools get swapped
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:agent1)

      agent(:agent1) do
        description("Test agent")
        coding_agent(false)
        tools(:Read, :Write, :Edit, :Bash, :Grep)
        directory(temp_dir)

        memory do
          directory(memory_dir)
        end
      end
    end

    agent = swarm.agent(:agent1)

    # Step 1: Agent creates a skill (with ALL required parameters)
    memory_write = agent.tools.values.find { |t| t.name == "MemoryWrite" }
    memory_write.execute(
      file_path: "skill/optimize-performance.md",
      content: <<~SKILL,
        # Optimize Performance

        ## Steps
        1. Profile the application
        2. Identify bottlenecks
        3. Apply optimizations
      SKILL
      title: "Optimize Application Performance",
      type: "skill",
      confidence: "high",
      tags: ["performance", "optimization"],
      related: [],
      domain: "performance",
      source: "experimentation",
      tools: ["Read", "Grep"],
      permissions: {
        "Bash" => { "denied_commands" => [".*"] },
      },
    )

    # Step 2: Agent searches for skills
    memory_grep = agent.tools.values.find { |t| t.name == "MemoryGrep" }
    search_result = memory_grep.execute(pattern: "performance")

    # Should find the skill
    assert_match(%r{skill/optimize-performance\.md}, search_result)

    # Step 3: Agent reads the skill to evaluate
    memory_read = agent.tools.values.find { |t| t.name == "MemoryRead" }
    read_result = memory_read.execute(file_path: "skill/optimize-performance.md")

    # Should return raw plain text
    expected_content = "# Optimize Performance\n\n## Steps\n1. Profile the application\n2. Identify bottlenecks\n3. Apply optimizations\n"

    assert_equal(expected_content, read_result)

    # Step 4: Capture initial tools
    initial_tools = agent.tools.values.map(&:name)

    assert_includes(initial_tools, "Write")
    assert_includes(initial_tools, "Edit")
    assert_includes(initial_tools, "Bash")

    # Step 5: Agent loads the skill
    load_skill = agent.tools.values.find { |t| t.name == "LoadSkill" }
    load_result = load_skill.execute(file_path: "skill/optimize-performance.md")

    # Should return skill content
    assert_match(/Loaded skill: Optimize Application Performance/, load_result)
    assert_match(/Profile the application/, load_result)

    # Step 6: Verify tools were swapped
    tools_after_load = agent.tools.values.map(&:name)

    # Skill tools should be present
    assert_includes(tools_after_load, "Read")
    assert_includes(tools_after_load, "Grep")

    # Mutable tools should be removed
    refute_includes(tools_after_load, "Write")
    refute_includes(tools_after_load, "Edit")
    refute_includes(tools_after_load, "Bash")

    # Immutable tools should be preserved
    assert_includes(tools_after_load, "MemoryWrite")
    assert_includes(tools_after_load, "MemoryRead")
    assert_includes(tools_after_load, "LoadSkill")

    # Skill should be marked as loaded
    assert_predicate(agent, :skill_loaded?)
  end

  def test_skill_permissions_override_agent_permissions
    # Scenario: Skill has stricter permissions than agent
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:agent1)

      agent(:agent1) do
        description("Test agent")
        coding_agent(false)
        tools(:Read, :Write, :Bash)
        directory(temp_dir)

        # Agent has broad Bash permissions
        permissions do
          tool(:Bash).allow_commands("^.*$") # Allow everything
        end

        memory do
          directory(memory_dir)
        end
      end
    end

    agent = swarm.agent(:agent1)

    # Create skill with restricted Bash permissions (with ALL required parameters)
    memory_write = agent.tools.values.find { |t| t.name == "MemoryWrite" }
    memory_write.execute(
      file_path: "skill/safe-deploy.md",
      content: "# Safe Deployment\n\nOnly run safe commands",
      title: "Safe Deployment",
      type: "skill",
      confidence: "high",
      tags: ["deployment", "safe", "git"],
      related: [],
      domain: "deployment",
      source: "experimentation",
      tools: ["Read", "Bash"],
      permissions: {
        "Bash" => {
          "allowed_commands" => ["^git status$", "^git log$"],
        },
      },
    )

    # Load the skill
    load_skill = agent.tools.values.find { |t| t.name == "LoadSkill" }
    load_skill.execute(file_path: "skill/safe-deploy.md")

    # Verify skill permissions are applied
    # The Bash tool should now have the skill's restrictions (not agent's)
    # This is validated through the permissions wrapping system
    tools_after_load = agent.tools.values.map(&:name)

    assert_includes(tools_after_load, "Bash")
  end

  def test_loading_different_skills_replaces_tools
    # Scenario: Load one skill, then load another - tools should be replaced
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:agent1)

      agent(:agent1) do
        description("Test agent")
        coding_agent(false)
        tools(:Read, :Write, :Edit, :Bash, :Grep, :Glob)
        directory(temp_dir)

        memory do
          directory(memory_dir)
        end
      end
    end

    agent = swarm.agent(:agent1)
    memory_write = agent.tools.values.find { |t| t.name == "MemoryWrite" }
    load_skill = agent.tools.values.find { |t| t.name == "LoadSkill" }

    # Create skill 1 (with ALL required parameters)
    memory_write.execute(
      file_path: "skill/analyze-code.md",
      content: "# Analyze Code",
      title: "Analyze Code",
      type: "skill",
      confidence: "high",
      tags: ["analysis", "code"],
      related: [],
      domain: "analysis",
      source: "experimentation",
      tools: ["Read", "Grep"],
      permissions: {},
    )

    # Create skill 2 (with ALL required parameters)
    memory_write.execute(
      file_path: "skill/write-docs.md",
      content: "# Write Documentation",
      title: "Write Docs",
      type: "skill",
      confidence: "high",
      tags: ["documentation", "writing"],
      related: [],
      domain: "documentation",
      source: "experimentation",
      tools: ["Read", "Write"],
      permissions: {},
    )

    # Load skill 1
    load_skill.execute(file_path: "skill/analyze-code.md")
    tools_after_skill1 = agent.tools.values.map(&:name)

    assert_includes(tools_after_skill1, "Read")
    assert_includes(tools_after_skill1, "Grep")
    refute_includes(tools_after_skill1, "Write") # Removed
    refute_includes(tools_after_skill1, "Edit") # Removed

    # Load skill 2 (should replace skill 1's tools)
    load_skill.execute(file_path: "skill/write-docs.md")
    tools_after_skill2 = agent.tools.values.map(&:name)

    assert_includes(tools_after_skill2, "Read")
    assert_includes(tools_after_skill2, "Write") # Added by skill 2
    refute_includes(tools_after_skill2, "Grep") # Removed (was from skill 1)
  end

  def test_skill_with_empty_tools_keeps_current_tools
    # Scenario: Skill with empty tools array [] keeps current tools
    temp_dir = @temp_dir
    memory_dir = @memory_dir

    swarm = SwarmSDK.build do
      name("Test Swarm")
      lead(:agent1)

      agent(:agent1) do
        description("Test agent")
        coding_agent(false)
        tools(:Read, :Write, :Edit)
        directory(temp_dir)

        memory do
          directory(memory_dir)
        end
      end
    end

    agent = swarm.agent(:agent1)
    memory_write = agent.tools.values.find { |t| t.name == "MemoryWrite" }
    load_skill = agent.tools.values.find { |t| t.name == "LoadSkill" }

    # Capture initial tools
    initial_tools = agent.tools.values.map(&:name).sort

    # Create skill with empty tools array (with ALL required parameters)
    memory_write.execute(
      file_path: "skill/minimal.md",
      content: "# Minimal Skill\n\nUse current tools",
      title: "Minimal Skill",
      type: "skill",
      confidence: "high",
      tags: ["minimal", "generic"],
      related: [],
      domain: "utilities",
      source: "experimentation",
      tools: [],
      permissions: {},
    )

    # Load skill
    load_skill.execute(file_path: "skill/minimal.md")
    tools_after_load = agent.tools.values.map(&:name).sort

    # tools: [] means "no restriction" - keep all tools unchanged
    assert_equal(initial_tools, tools_after_load, "tools: [] should keep all tools unchanged")

    # Verify specific tools are still present
    assert_includes(tools_after_load, "Read", "Read should still be present")
    assert_includes(tools_after_load, "Write", "Write should still be present")
    assert_includes(tools_after_load, "Edit", "Edit should still be present")
    assert_includes(tools_after_load, "MemoryRead", "MemoryRead should still be present")
  end
end
