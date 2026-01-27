# frozen_string_literal: true

require_relative "../../swarm_memory_test_helper"

# Test virtual built-in entries in FilesystemAdapter
class VirtualEntriesTest < Minitest::Test
  def setup
    @storage = create_temp_storage
  end

  def teardown
    cleanup_storage(@storage)
  end

  def test_deep_learning_protocol_skill_is_always_available
    # Virtual skill should be readable even without being written
    entry = @storage.read_entry(file_path: "skill/meta/deep-learning.md")

    assert_equal("Deep Learning Protocol", entry.title)
    assert_equal("skill", entry.metadata["type"])
    assert_equal("high", entry.metadata["confidence"])
    assert_includes(entry.metadata["tags"], "learning")
    assert_includes(entry.metadata["tags"], "meta")
    assert_empty(entry.metadata["tools"])
    assert_empty(entry.metadata["permissions"])
    assert_match(/Deep Learning Protocol/, entry.content)
    assert_match(/Define Scope/, entry.content)
    assert_match(/Self-Test Understanding/, entry.content)
  end

  def test_virtual_skill_works_with_memory_read_tool
    # MemoryRead should return plain text for virtual entries
    tool = SwarmMemory::Tools::MemoryRead.new(storage: @storage, agent_name: :test)
    result = tool.execute(file_path: "skill/meta/deep-learning.md")

    # Should return raw plain text
    assert_match(/# Deep Learning Protocol/, result)
    assert_match(/Define Scope/, result)
  end

  def test_virtual_skill_works_with_load_skill_tool
    # Create mock components for LoadSkill
    chat = MockChat.new
    tool_configurator = MockToolConfigurator.new
    agent_definition = MockAgentDefinition.new

    # Create LoadSkill tool
    load_skill = SwarmMemory::Tools::LoadSkill.new(
      storage: @storage,
      agent_name: :test,
      chat: chat,
      tool_configurator: tool_configurator,
      agent_definition: agent_definition,
    )

    # Add some mutable tools
    chat.add_tool(MockTool.new("Read"))
    chat.add_tool(MockTool.new("Write"))

    # Load the virtual skill
    result = load_skill.execute(file_path: "skill/meta/deep-learning.md")

    # Should succeed
    assert_match(/Loaded skill: Deep Learning Protocol/, result)
    assert_match(/Define Scope/, result)
    assert_match(/Self-Test Understanding/, result)

    # Skill should be marked as loaded
    assert_predicate(chat, :skill_loaded?)
  end

  def test_virtual_entry_does_not_take_storage_space
    # Storage should be empty
    assert_equal(0, @storage.size)
    assert_equal(0, @storage.total_size)

    # Read virtual entry
    @storage.read_entry(file_path: "skill/meta/deep-learning.md")

    # Storage should still be empty
    assert_equal(0, @storage.size)
    assert_equal(0, @storage.total_size)
  end

  def test_virtual_entry_cannot_be_overwritten
    # Try to write to the same path as virtual entry
    @storage.write(
      file_path: "skill/meta/deep-learning.md",
      content: "Overwrite attempt",
      title: "Should Not Work",
      metadata: { "type" => "skill" },
    )

    # Virtual entry should still be returned (not the written one)
    entry = @storage.read_entry(file_path: "skill/meta/deep-learning.md")

    assert_equal("Deep Learning Protocol", entry.title)
    assert_match(/Deep Learning Protocol/, entry.content)
    refute_match(/Overwrite attempt/, entry.content)
  end

  def test_regular_entries_still_work_normally
    # Write a regular entry
    @storage.write(
      file_path: "skill/my-custom-skill.md",
      content: "My custom skill content",
      title: "Custom Skill",
      metadata: { "type" => "skill" },
    )

    # Should be readable
    entry = @storage.read_entry(file_path: "skill/my-custom-skill.md")

    assert_equal("Custom Skill", entry.title)
    assert_match(/My custom skill content/, entry.content)

    # Should count toward storage
    assert_equal(1, @storage.size)
    assert_operator(@storage.total_size, :>, 0)
  end
end

# Mock classes needed for LoadSkill test
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
