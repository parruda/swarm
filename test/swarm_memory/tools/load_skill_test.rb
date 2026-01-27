# frozen_string_literal: true

require_relative "../../swarm_memory_test_helper"

# Mock classes for testing LoadSkill without full SwarmSDK setup
class MockChat
  attr_reader :tools, :tool_registry, :skill_state

  def initialize
    @tools = {} # Hash to match real Chat behavior
    @tool_registry = SwarmSDK::Agent::ToolRegistry.new
    @skill_state = nil
  end

  def load_skill_state(state)
    @skill_state = state
  end

  def skill_loaded?
    !@skill_state.nil?
  end

  def active_skill_path
    @skill_state&.file_path
  end

  def add_tool(tool)
    @tools[tool.name] = tool # Store by name as key
  end
  alias_method :with_tool, :add_tool

  # Mock implementation for Plan 025
  def activate_tools_for_prompt
    # Simulate lazy activation based on skill_state
    active = @tool_registry.active_tools(skill_state: @skill_state)
    @tools = active
  end
end

class MockTool
  attr_reader :name

  def initialize(name, removable: true)
    @name = name
    @removable = removable
  end

  def removable?
    @removable
  end
end

class MockToolConfigurator
  def create_tool_instance(tool_name, agent_name, directory)
    MockTool.new(tool_name.to_s)
  end

  def wrap_tool_with_permissions(tool_instance, permissions, agent_definition)
    tool_instance
  end
end

class MockAgentDefinition
  attr_reader :bypass_permissions, :directory

  def initialize(bypass: false, directory: "/test", memory_config: nil)
    @bypass_permissions = bypass
    @directory = directory
    @memory_config = memory_config
  end

  # Required for LoadSkill delegation preservation
  def plugin_config(plugin_name)
    return @memory_config if plugin_name == :memory

    nil
  end
end

# Mock memory config for testing delegation preservation
class MockMemoryConfig
  attr_reader :loadskill_preserve_delegation_value

  def initialize(preserve: true)
    @loadskill_preserve_delegation_value = preserve
  end

  def loadskill_preserve_delegation
    @loadskill_preserve_delegation_value
  end
end

# Mock delegation tool for testing
class MockDelegationTool < SwarmSDK::Tools::Delegate
  # rubocop:disable Lint/MissingSuper
  def initialize(name:)
    # Don't call super - we don't need full initialization for testing
    # The parent class requires parameters we don't have in tests
    @tool_name = name
    @delegate_name = name
  end
  # rubocop:enable Lint/MissingSuper

  def name
    @tool_name
  end
end

class LoadSkillToolTest < Minitest::Test
  def setup
    @storage = create_temp_storage
    @chat = MockChat.new
    @tool_configurator = MockToolConfigurator.new
    @agent_definition = MockAgentDefinition.new

    # Register mock tools in registry (Plan 025)
    # Removable tools
    ["Read", "Write", "Edit", "Bash", "Grep", "Glob"].each do |tool_name|
      mock_tool = MockTool.new(tool_name, removable: true)
      @chat.tool_registry.register(mock_tool, source: :builtin)
    end

    # Non-removable built-in tools
    ["Think", "Clock", "TodoWrite"].each do |tool_name|
      mock_tool = MockTool.new(tool_name, removable: false)
      @chat.tool_registry.register(mock_tool, source: :builtin)
    end

    # Non-removable memory tools
    ["MemoryRead", "MemoryWrite", "MemoryEdit", "MemoryDelete", "MemoryGlob", "MemoryGrep", "MemoryDefrag", "LoadSkill"].each do |tool_name|
      mock_tool = MockTool.new(tool_name, removable: false)
      @chat.tool_registry.register(mock_tool, source: :plugin)
    end

    # Create LoadSkill tool
    @tool = SwarmMemory::Tools::LoadSkill.new(
      storage: @storage,
      agent_name: :test_agent,
      chat: @chat,
      tool_configurator: @tool_configurator,
      agent_definition: @agent_definition,
    )
  end

  def teardown
    cleanup_storage(@storage)
  end

  # Removed: test_marks_memory_tools_as_immutable (obsolete - Plan 025)
  # Memory tools now declare removable false themselves, no need to mark immutable

  def test_fail_if_not_in_skills_hierarchy
    # Create a non-skill entry
    @storage.write(
      file_path: "test/not-skill.md",
      content: "Regular entry",
      title: "Not a Skill",
      metadata: { "type" => "concept" },
    )

    result = @tool.execute(file_path: "test/not-skill.md")

    assert_match(/InputValidationError/, result)
    assert_match(%r{Skills must be stored in skill/ hierarchy}, result)
  end

  def test_fail_if_not_skill_type
    # Create entry in skill/ but wrong type
    @storage.write(
      file_path: "skill/not-skill.md",
      content: "Not actually a skill",
      title: "Not a Skill",
      metadata: { "type" => "concept" },
    )

    result = @tool.execute(file_path: "skill/not-skill.md")

    assert_match(/InputValidationError/, result)
    assert_match(/is not a skill/, result)
  end

  def test_fail_for_nonexistent_skill
    result = @tool.execute(file_path: "skill/nonexistent.md")

    assert_match(/InputValidationError/, result)
    assert_match(/not found/, result)
  end

  def test_load_skill_with_tools
    # Create a valid skill
    @storage.write(
      file_path: "skill/debug-react.md",
      content: "# Debug React\n\n1. Profile\n2. Optimize",
      title: "Debug React Performance",
      metadata: {
        "type" => "skill",
        "tools" => ["Read", "Edit", "Bash"],
      },
    )

    # Add some initial mutable tools to chat
    @chat.add_tool(MockTool.new("Write"))
    @chat.add_tool(MockTool.new("Grep"))
    @chat.add_tool(MockTool.new("Think")) # Immutable
    @chat.add_tool(MockTool.new("Clock")) # Immutable
    @chat.add_tool(MockTool.new("TodoWrite")) # Immutable

    assert_equal(5, @chat.tools.size)

    result = @tool.execute(file_path: "skill/debug-react.md")

    # Should succeed
    assert_match(/Loaded skill: Debug React Performance/, result)
    assert_match(/Profile/, result)
    assert_match(/Optimize/, result)

    # Verify mutable tools were replaced
    tool_names = @chat.tools.values.map(&:name)

    assert_includes(tool_names, "Read")
    assert_includes(tool_names, "Edit")
    assert_includes(tool_names, "Bash")
    assert_includes(tool_names, "Think") # Immutable preserved
    assert_includes(tool_names, "Clock") # Immutable preserved
    assert_includes(tool_names, "TodoWrite") # Immutable preserved

    # Mutable tools should be removed
    refute_includes(tool_names, "Write")
    refute_includes(tool_names, "Grep")

    # Skill should be marked as loaded
    assert_predicate(@chat, :skill_loaded?)
    assert_equal("skill/debug-react.md", @chat.active_skill_path)
  end

  def test_load_skill_without_tools_keeps_current_tools
    # Create skill without tools specified (nil)
    @storage.write(
      file_path: "skill/simple.md",
      content: "# Simple Task",
      title: "Simple Task",
      metadata: { "type" => "skill" },
    )

    # Add some tools to chat to verify they're preserved
    @chat.add_tool(MockTool.new("Write"))
    @chat.add_tool(MockTool.new("Read"))
    @chat.add_tool(MockTool.new("Think", removable: false))

    initial_tool_count = @chat.tools.size

    result = @tool.execute(file_path: "skill/simple.md")

    # Should succeed
    assert_match(/Loaded skill: Simple Task/, result)

    # Plan 025: tools: nil means "no restriction" → tools stay unchanged
    final_tool_count = @chat.tools.size

    # Tools should be unchanged (LoadSkill doesn't call activate_tools_for_prompt when no restriction)
    assert_equal(initial_tool_count, final_tool_count, "Tool count should remain unchanged when skill has no tool restriction")

    # Original tools should still be present
    assert(@chat.tools["Write"], "Write should still be present")
    assert(@chat.tools["Read"], "Read should still be present")
    assert(@chat.tools["Think"], "Think should still be present")
  end

  def test_load_skill_preserves_immutable_tools
    # Create skill
    @storage.write(
      file_path: "skill/test.md",
      content: "# Test Skill",
      title: "Test",
      metadata: {
        "type" => "skill",
        "tools" => ["Read"],
      },
    )

    # Add memory tools (should be immutable)
    @chat.add_tool(MockTool.new("MemoryRead"))
    @chat.add_tool(MockTool.new("MemoryWrite"))
    @chat.add_tool(MockTool.new("LoadSkill"))
    @chat.add_tool(MockTool.new("Think"))
    @chat.add_tool(MockTool.new("Clock"))
    @chat.add_tool(MockTool.new("TodoWrite"))
    @chat.add_tool(MockTool.new("Write")) # Mutable

    result = @tool.execute(file_path: "skill/test.md")

    assert_match(/Loaded skill: Test/, result)

    # All immutable tools should be preserved
    tool_names = @chat.tools.values.map(&:name)

    assert_includes(tool_names, "MemoryRead")
    assert_includes(tool_names, "MemoryWrite")
    assert_includes(tool_names, "LoadSkill")
    assert_includes(tool_names, "Think")
    assert_includes(tool_names, "Clock")
    assert_includes(tool_names, "TodoWrite")
    assert_includes(tool_names, "Read") # Added by skill

    # Mutable tool should be removed
    refute_includes(tool_names, "Write")
  end

  def test_load_multiple_skills_replaces_tools
    # Create two skills
    @storage.write(
      file_path: "skill/skill1.md",
      content: "# Skill 1",
      title: "Skill 1",
      metadata: {
        "type" => "skill",
        "tools" => ["Read", "Edit"],
      },
    )

    @storage.write(
      file_path: "skill/skill2.md",
      content: "# Skill 2",
      title: "Skill 2",
      metadata: {
        "type" => "skill",
        "tools" => ["Write", "Bash"],
      },
    )

    # Add immutable tools
    @chat.add_tool(MockTool.new("Think"))
    @chat.add_tool(MockTool.new("Clock"))
    @chat.add_tool(MockTool.new("TodoWrite"))

    # Load first skill
    @tool.execute(file_path: "skill/skill1.md")
    tools_after_first = @chat.tools.values.map(&:name)

    assert_includes(tools_after_first, "Read")
    assert_includes(tools_after_first, "Edit")
    assert_equal("skill/skill1.md", @chat.active_skill_path)

    # Load second skill (should replace first skill's tools)
    @tool.execute(file_path: "skill/skill2.md")
    tools_after_second = @chat.tools.values.map(&:name)

    assert_includes(tools_after_second, "Write")
    assert_includes(tools_after_second, "Bash")
    assert_includes(tools_after_second, "Think") # Immutable preserved
    assert_includes(tools_after_second, "Clock") # Immutable preserved
    assert_includes(tools_after_second, "TodoWrite") # Immutable preserved

    # First skill's tools should be gone
    refute_includes(tools_after_second, "Read")
    refute_includes(tools_after_second, "Edit")
    assert_equal("skill/skill2.md", @chat.active_skill_path)
  end

  def test_returns_content_without_line_numbers
    @storage.write(
      file_path: "skill/test.md",
      content: "Line 1\nLine 2\nLine 3",
      title: "Test",
      metadata: { "type" => "skill", "tools" => [] },
    )

    result = @tool.execute(file_path: "skill/test.md")

    # Should include raw content without line numbers
    assert_includes(result, "Line 1\nLine 2\nLine 3")
    # Should NOT include line number formatting
    refute_match(/     1→/, result)
  end
end
