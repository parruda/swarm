# frozen_string_literal: true

require_relative "../../swarm_memory_test_helper"

class MemoryReadToolTest < Minitest::Test
  def setup
    @storage = create_temp_storage
    @tool = SwarmMemory::Tools::MemoryRead.new(storage: @storage, agent_name: :test_agent)
  end

  def teardown
    cleanup_storage(@storage)
  end

  def test_returns_raw_content
    # Write entry with minimal metadata
    @storage.write(
      file_path: "test/plain.md",
      content: "Line 1\nLine 2\nLine 3",
      title: "Plain Entry",
      metadata: { "type" => "fact" },
    )

    result = @tool.execute(file_path: "test/plain.md")

    # Should return raw plain text (not JSON, no line numbers)
    assert_equal("Line 1\nLine 2\nLine 3", result)

    # Should NOT be JSON
    assert_raises(JSON::ParserError) { JSON.parse(result) }
  end

  def test_returns_content_without_metadata_wrapper
    # Write entry with full metadata
    @storage.write(
      file_path: "test/with_meta.md",
      content: "Content with metadata",
      title: "Entry With Metadata",
      metadata: {
        "type" => "concept",
        "confidence" => "high",
        "tags" => ["test", "ruby"],
      },
    )

    result = @tool.execute(file_path: "test/with_meta.md")

    # Should return raw plain text
    assert_equal("Content with metadata", result)

    # Should NOT include JSON structure or metadata fields
    refute_match(/"metadata"/, result)
    refute_match(/"content"/, result)
  end

  def test_skill_content_returns_plain_text
    # Write skill entry with tools and permissions
    @storage.write(
      file_path: "skill/debug-react.md",
      content: "# Debug React Performance\n\n1. Profile components\n2. Check re-renders",
      title: "Debug React Performance",
      metadata: {
        "type" => "skill",
        "confidence" => "high",
        "tags" => ["react", "performance"],
        "tools" => ["Read", "Edit", "Bash"],
        "permissions" => {
          "Bash" => { "allowed_commands" => ["^npm", "^git"] },
        },
      },
    )

    result = @tool.execute(file_path: "skill/debug-react.md")

    # Should return raw plain content
    assert_equal("# Debug React Performance\n\n1. Profile components\n2. Check re-renders", result)

    # Should NOT include metadata in output
    refute_match(/"tools"/, result)
    refute_match(/"permissions"/, result)
  end

  def test_includes_related_memories_reminder
    # Write a related memory first
    @storage.write(
      file_path: "concept/ruby/modules.md",
      content: "Ruby modules provide mixins",
      title: "Ruby Modules",
      metadata: { "type" => "concept" },
    )

    # Write main entry with related memory
    @storage.write(
      file_path: "concept/ruby/classes.md",
      content: "Ruby classes are blueprints",
      title: "Ruby Classes",
      metadata: {
        "type" => "concept",
        "related" => ["memory://concept/ruby/modules.md"],
      },
    )

    result = @tool.execute(file_path: "concept/ruby/classes.md")

    # Should include system-reminder with related memories
    assert_match(/<system-reminder>/, result)
    assert_match(/Related memories that may provide additional context:/, result)
    assert_match(%r{memory://concept/ruby/modules\.md "Ruby Modules"}, result)
    assert_match(%r{</system-reminder>}, result)
  end

  def test_related_memories_without_prefix
    # Write a related memory first
    @storage.write(
      file_path: "concept/ruby/inheritance.md",
      content: "Ruby inheritance",
      title: "Ruby Inheritance",
      metadata: { "type" => "concept" },
    )

    # Write main entry with related memory (without memory:// prefix)
    @storage.write(
      file_path: "concept/ruby/classes.md",
      content: "Ruby classes content",
      title: "Ruby Classes",
      metadata: {
        "type" => "concept",
        "related" => ["concept/ruby/inheritance.md"],
      },
    )

    result = @tool.execute(file_path: "concept/ruby/classes.md")

    # Should normalize path and include with memory:// prefix
    assert_match(%r{memory://concept/ruby/inheritance\.md "Ruby Inheritance"}, result)
  end

  def test_related_memory_not_found_shows_path_only
    # Write main entry with related memory that doesn't exist
    @storage.write(
      file_path: "concept/ruby/classes.md",
      content: "Ruby classes content",
      title: "Ruby Classes",
      metadata: {
        "type" => "concept",
        "related" => ["memory://concept/ruby/nonexistent.md"],
      },
    )

    result = @tool.execute(file_path: "concept/ruby/classes.md")

    # Should include the path without title (since memory doesn't exist)
    assert_match(/<system-reminder>/, result)
    assert_match(%r{- memory://concept/ruby/nonexistent\.md$}, result)
    # Should NOT have a quoted title
    refute_match(/nonexistent\.md "/, result)
  end

  def test_no_related_memories_no_reminder
    # Write entry without related memories
    @storage.write(
      file_path: "concept/ruby/classes.md",
      content: "Ruby classes content",
      title: "Ruby Classes",
      metadata: { "type" => "concept" },
    )

    result = @tool.execute(file_path: "concept/ruby/classes.md")

    # Should NOT include system-reminder section
    refute_match(/<system-reminder>/, result)
    refute_match(/Related memories/, result)
  end

  def test_empty_related_array_no_reminder
    # Write entry with empty related array
    @storage.write(
      file_path: "concept/ruby/classes.md",
      content: "Ruby classes content",
      title: "Ruby Classes",
      metadata: {
        "type" => "concept",
        "related" => [],
      },
    )

    result = @tool.execute(file_path: "concept/ruby/classes.md")

    # Should NOT include system-reminder section
    refute_match(/<system-reminder>/, result)
  end

  def test_multiple_related_memories
    # Write related memories
    @storage.write(
      file_path: "concept/ruby/modules.md",
      content: "Ruby modules",
      title: "Ruby Modules",
      metadata: { "type" => "concept" },
    )
    @storage.write(
      file_path: "concept/ruby/inheritance.md",
      content: "Ruby inheritance",
      title: "Ruby Inheritance",
      metadata: { "type" => "concept" },
    )

    # Write main entry with multiple related memories
    @storage.write(
      file_path: "concept/ruby/classes.md",
      content: "Ruby classes content",
      title: "Ruby Classes",
      metadata: {
        "type" => "concept",
        "related" => [
          "memory://concept/ruby/modules.md",
          "memory://concept/ruby/inheritance.md",
        ],
      },
    )

    result = @tool.execute(file_path: "concept/ruby/classes.md")

    # Should include both related memories
    assert_match(%r{memory://concept/ruby/modules\.md "Ruby Modules"}, result)
    assert_match(%r{memory://concept/ruby/inheritance\.md "Ruby Inheritance"}, result)
  end

  def test_error_for_nonexistent_file
    result = @tool.execute(file_path: "nonexistent.md")

    assert_match(/InputValidationError/, result)
    assert_match(/not found/, result)
  end
end
