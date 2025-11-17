# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class ClaudeCodeAgentAdapterTest < Minitest::Test
    # Format Detection Tests

    def test_does_not_detect_without_tools_field
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        ---

        System prompt here.
      MD

      # Name field alone is not enough - need comma-separated tools to detect Claude Code format
      refute(ClaudeCodeAgentAdapter.claude_code_format?(content))
    end

    def test_detects_claude_code_format_with_comma_separated_tools
      content = <<~MD
        ---
        description: A test agent
        tools: Read, Write, Bash
        ---

        System prompt here.
      MD

      assert(ClaudeCodeAgentAdapter.claude_code_format?(content))
    end

    def test_does_not_detect_swarm_sdk_format_with_array_tools
      content = <<~MD
        ---
        description: A test agent
        tools:
          - Read
          - Write
        ---

        System prompt here.
      MD

      refute(ClaudeCodeAgentAdapter.claude_code_format?(content))
    end

    def test_returns_false_for_invalid_yaml
      content = <<~MD
        ---
        invalid: yaml: syntax:
        ---

        System prompt here.
      MD

      refute(ClaudeCodeAgentAdapter.claude_code_format?(content))
    end

    def test_returns_false_for_no_frontmatter
      content = "Just plain markdown text"

      refute(ClaudeCodeAgentAdapter.claude_code_format?(content))
    end

    # Model Shortcut Tests

    def test_maps_sonnet_shortcut_to_full_model_id
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        model: sonnet
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal("claude-sonnet-4-5-20250929", config[:model])
    end

    def test_maps_opus_shortcut_to_full_model_id
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        model: opus
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal("claude-opus-4-1-20250805", config[:model])
    end

    def test_maps_haiku_shortcut_to_full_model_id
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        model: haiku
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal("claude-haiku-4-5-20251001", config[:model])
    end

    def test_handles_inherit_keyword
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        model: inherit
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal(:inherit, config[:model])
    end

    def test_passes_through_full_model_id
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        model: claude-opus-4-20250514
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal("claude-opus-4-20250514", config[:model])
    end

    # Tools Parsing Tests

    def test_parses_comma_separated_tools_to_array
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        tools: Read, Write, Bash
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal(["Read", "Write", "Bash"], config[:tools])
    end

    def test_trims_whitespace_from_tool_names
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        tools:  Read  ,  Write  ,  Bash
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal(["Read", "Write", "Bash"], config[:tools])
    end

    def test_handles_tools_as_array
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        tools:
          - Read
          - Write
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal(["Read", "Write"], config[:tools])
    end

    def test_strips_tool_permissions_and_warns
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        tools: Read, Write(src/**), Bash
        ---

        System prompt here.
      MD

      # Capture log events
      events = []
      LogCollector.subscribe { |event| events << event }

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal(["Read", "Write", "Bash"], config[:tools])

      # Check warnings were emitted
      warnings = events.select { |e| e[:type] == "claude_code_conversion_warning" }

      assert_equal(1, warnings.size)
      assert_match(%r{Tool permission syntax 'Write\(src/\*\*\)' detected}, warnings.first[:message])
      assert_match(/SwarmSDK supports permissions but uses different syntax/, warnings.first[:message])
    ensure
      LogCollector.reset!
    end

    def test_handles_multiple_tool_permissions
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        tools: Read(foo/**), Write(bar/**), Edit(baz/**)
        ---

        System prompt here.
      MD

      # Capture log events
      events = []
      LogCollector.subscribe { |event| events << event }

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal(["Read", "Write", "Edit"], config[:tools])

      # Check warnings were emitted
      warnings = events.select { |e| e[:type] == "claude_code_conversion_warning" }

      assert_equal(3, warnings.size)

      messages = warnings.map { |w| w[:message] }.join

      assert_match(%r{Read\(foo/\*\*\)}, messages)
      assert_match(%r{Write\(bar/\*\*\)}, messages)
      assert_match(%r{Edit\(baz/\*\*\)}, messages)
    ensure
      LogCollector.reset!
    end

    # Configuration Field Tests

    def test_includes_description
      content = <<~MD
        ---
        name: test-agent
        description: A helpful test agent
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal("A helpful test agent", config[:description])
    end

    def test_includes_system_prompt
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        ---

        You are a helpful assistant.
        Follow these guidelines.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_equal("You are a helpful assistant.\nFollow these guidelines.", config[:system_prompt])
    end

    def test_sets_coding_agent_true_by_default
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert(config[:coding_agent])
    end

    # Warning Tests

    def test_warns_about_unknown_fields
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        custom_field: custom_value
        another_field: another_value
        ---

        System prompt here.
      MD

      # Capture log events
      events = []
      LogCollector.subscribe { |event| events << event }

      ClaudeCodeAgentAdapter.parse(content, :test)

      # Check warnings were emitted
      warnings = events.select { |e| e[:type] == "claude_code_conversion_warning" }
      messages = warnings.map { |w| w[:message] }.join

      assert_match(/Unknown field 'custom_field'/, messages)
      assert_match(/Unknown field 'another_field'/, messages)
    ensure
      LogCollector.reset!
    end

    def test_warns_about_hooks_field
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        hooks:
          PreToolUse:
            - matcher: Write
        ---

        System prompt here.
      MD

      # Capture log events
      events = []
      LogCollector.subscribe { |event| events << event }

      ClaudeCodeAgentAdapter.parse(content, :test)

      # Check warnings were emitted
      warnings = events.select { |e| e[:type] == "claude_code_conversion_warning" }
      messages = warnings.map { |w| w[:message] }.join

      assert_match(/Hooks configuration detected in agent frontmatter/, messages)
      assert_match(/SwarmSDK handles hooks at the swarm level/, messages)
      assert_match(%r{https://github.com/parruda/claude-swarm/blob/main/docs/v2/README.md}, messages)
    ensure
      LogCollector.reset!
    end

    # Integration with MarkdownParser Tests

    def test_markdown_parser_detects_and_uses_adapter
      content = <<~MD
        ---
        name: code-reviewer
        description: Expert code reviewer
        tools: Read, Grep, Glob
        model: sonnet
        ---

        You are a senior code reviewer.
      MD

      agent_def = MarkdownParser.parse(content, :reviewer)

      assert_equal(:reviewer, agent_def.name)
      assert_equal("Expert code reviewer", agent_def.description)
      # Tools are stored as hashes with :name and :permissions keys
      assert_equal([:Read, :Grep, :Glob], agent_def.tools.map { |t| t[:name] })
      assert_equal("claude-sonnet-4-5-20250929", agent_def.model)
      # Since coding_agent is true by default, system prompt includes base prompt + custom
      assert_match(/You are a senior code reviewer\./, agent_def.system_prompt)
      assert(agent_def.coding_agent)
    end

    def test_markdown_parser_uses_swarm_sdk_format_when_not_claude_code
      content = <<~MD
        ---
        description: A test agent
        tools:
          - Read
          - Write
        coding_agent: false
        ---

        System prompt here.
      MD

      agent_def = MarkdownParser.parse(content, :test)

      assert_equal(:test, agent_def.name)
      # Tools are stored as hashes with :name and :permissions keys
      assert_equal([:Read, :Write], agent_def.tools.map { |t| t[:name] })
      refute(agent_def.coding_agent)
    end

    # Edge Cases

    def test_handles_empty_tools_field
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        tools:
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_nil(config[:tools])
    end

    def test_handles_missing_model_field
      content = <<~MD
        ---
        name: test-agent
        description: A test agent
        ---

        System prompt here.
      MD

      config = ClaudeCodeAgentAdapter.parse(content, :test)

      assert_nil(config[:model])
    end

    def test_raises_error_for_invalid_frontmatter
      content = <<~MD
        ---
        invalid yaml syntax [
        ---

        System prompt here.
      MD

      assert_raises(ConfigurationError) do
        ClaudeCodeAgentAdapter.parse(content, :test)
      end
    end

    def test_raises_error_for_missing_frontmatter
      content = "Just plain markdown without frontmatter"

      assert_raises(ConfigurationError) do
        ClaudeCodeAgentAdapter.parse(content, :test)
      end
    end

    # Complete Example Test

    def test_complete_claude_code_agent_file
      content = <<~MD
        ---
        name: code-reviewer
        description: Expert code reviewer. Use proactively after code changes.
        tools: Read, Grep, Glob, Write(src/**), Bash
        model: sonnet
        hooks:
          PreToolUse:
            - matcher: Write
        custom_field: ignored
        ---

        You are a senior code reviewer ensuring high standards of code quality.

        When invoked:
        1. Run git diff to see recent changes
        2. Focus on modified files
        3. Begin review immediately
      MD

      # Capture log events
      events = []
      LogCollector.subscribe { |event| events << event }

      config = ClaudeCodeAgentAdapter.parse(content, :reviewer)

      # Verify all fields were parsed correctly
      assert_equal("Expert code reviewer. Use proactively after code changes.", config[:description])
      assert_equal(["Read", "Grep", "Glob", "Write", "Bash"], config[:tools])
      assert_equal("claude-sonnet-4-5-20250929", config[:model])
      assert(config[:coding_agent])
      assert_match(/You are a senior code reviewer/, config[:system_prompt])

      # Verify warnings were emitted
      warnings = events.select { |e| e[:type] == "claude_code_conversion_warning" }
      messages = warnings.map { |w| w[:message] }.join

      assert_match(%r{Tool permission syntax 'Write\(src/\*\*\)'}, messages)
      assert_match(/Hooks configuration detected/, messages)
      assert_match(/Unknown field 'custom_field'/, messages)
    ensure
      LogCollector.reset!
    end
  end
end
