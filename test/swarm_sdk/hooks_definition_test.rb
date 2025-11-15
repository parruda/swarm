# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class HooksDefinitionTest < Minitest::Test
    def test_hook_without_matcher_matches_all_tools
      # Hook without matcher should match ALL tools
      hook = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: nil, # No matcher
        priority: 0,
        proc: ->(_ctx) {},
      )

      # Should match any tool
      assert(hook.matches?("Read"), "Should match Read")
      assert(hook.matches?("Write"), "Should match Write")
      assert(hook.matches?("Bash"), "Should match Bash")
      assert(hook.matches?("Glob"), "Should match Glob")
      assert(hook.matches?("Edit"), "Should match Edit")
      assert(hook.matches?("WorkWithBackend"), "Should match delegation tools")
      assert(hook.matches?("AnyToolName"), "Should match any tool name")
    end

    def test_hook_with_single_tool_matcher
      # Hook with specific tool matcher
      hook = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: "Write",
        priority: 0,
        proc: ->(_ctx) {},
      )

      # Should only match Write
      assert(hook.matches?("Write"), "Should match Write")
      refute(hook.matches?("Read"), "Should not match Read")
      refute(hook.matches?("Bash"), "Should not match Bash")
    end

    def test_hook_with_pipe_separated_matcher
      # Hook with multiple tools (pipe-separated regex)
      hook = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: "Write|Edit|MultiEdit",
        priority: 0,
        proc: ->(_ctx) {},
      )

      # Should match all listed tools
      assert(hook.matches?("Write"), "Should match Write")
      assert(hook.matches?("Edit"), "Should match Edit")
      assert(hook.matches?("MultiEdit"), "Should match MultiEdit")

      # Should not match others
      refute(hook.matches?("Read"), "Should not match Read")
      refute(hook.matches?("Bash"), "Should not match Bash")
    end

    def test_hook_with_regex_pattern_matcher
      # Hook with regex pattern
      hook = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: "WorkWith.*",
        priority: 0,
        proc: ->(_ctx) {},
      )

      # Should match delegation tools
      assert(hook.matches?("WorkWithBackend"), "Should match WorkWithBackend")
      assert(hook.matches?("WorkWithFrontend"), "Should match WorkWithFrontend")
      assert(hook.matches?("WorkWithAnything"), "Should match WorkWithAnything")

      # Should not match non-delegation tools
      refute(hook.matches?("Read"), "Should not match Read")
      refute(hook.matches?("Write"), "Should not match Write")
    end

    def test_hook_priority_ordering
      # Hooks should be sortable by priority
      high_priority = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: nil,
        priority: 100,
        proc: ->(_ctx) {},
      )

      low_priority = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: nil,
        priority: 0,
        proc: ->(_ctx) {},
      )

      # Higher priority should sort first
      hooks = [low_priority, high_priority]
      sorted = hooks.sort_by { |h| -h.priority } # Descending

      assert_equal(high_priority, sorted.first)
      assert_equal(low_priority, sorted.last)
    end

    def test_named_hook_detection
      # Test named_hook? method
      named_hook = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: nil,
        priority: 0,
        proc: :my_named_hook, # Symbol = named hook
      )

      proc_hook = Hooks::Definition.new(
        event: :pre_tool_use,
        matcher: nil,
        priority: 0,
        proc: ->(_ctx) {}, # Proc = inline hook
      )

      assert_predicate(named_hook, :named_hook?)
      refute_predicate(proc_hook, :named_hook?)
    end
  end
end
