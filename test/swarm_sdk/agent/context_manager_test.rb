# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Agent
    class ContextManagerTest < Minitest::Test
      def setup
        @manager = ContextManager.new
      end

      # Ephemeral content tests
      def test_add_ephemeral_content_for_message
        @manager.add_ephemeral_content_for_message(0, "First reminder")
        @manager.add_ephemeral_content_for_message(0, "Second reminder")

        assert_predicate(@manager, :has_ephemeral?)
        assert_equal(1, @manager.ephemeral_count)
      end

      def test_add_ephemeral_reminder_with_valid_messages
        messages = [
          RubyLLM::Message.new(role: :user, content: "Hello"),
          RubyLLM::Message.new(role: :assistant, content: "Hi there"),
        ]

        @manager.add_ephemeral_reminder("<system-reminder>Test</system-reminder>", messages_array: messages)

        assert_predicate(@manager, :has_ephemeral?)
        assert_equal(1, @manager.ephemeral_count)
      end

      def test_add_ephemeral_reminder_with_empty_messages_array
        messages = []

        @manager.add_ephemeral_reminder("<system-reminder>Test</system-reminder>", messages_array: messages)

        # Should not add ephemeral when message_index < 0
        refute_predicate(@manager, :has_ephemeral?)
        assert_equal(0, @manager.ephemeral_count)
      end

      def test_clear_ephemeral
        @manager.add_ephemeral_content_for_message(0, "Test")

        @manager.clear_ephemeral

        refute_predicate(@manager, :has_ephemeral?)
        assert_equal(0, @manager.ephemeral_count)
      end

      def test_prepare_for_llm_with_no_ephemeral
        messages = [
          RubyLLM::Message.new(role: :user, content: "Hello"),
        ]

        result = @manager.prepare_for_llm(messages)

        # Should return a copy of the original
        assert_equal(1, result.size)
        assert_equal("Hello", result.first.content)
        refute_same(messages, result) # Different array
      end

      def test_prepare_for_llm_embeds_ephemeral_with_plain_string
        messages = [
          RubyLLM::Message.new(role: :user, content: "Hello"),
        ]

        @manager.add_ephemeral_content_for_message(0, "<system-reminder>Be careful</system-reminder>")

        result = @manager.prepare_for_llm(messages)

        assert_equal(1, result.size)
        assert_includes(result.first.content, "Hello")
        assert_includes(result.first.content, "<system-reminder>Be careful</system-reminder>")
        refute_includes(messages.first.content, "system-reminder") # Original unchanged
      end

      def test_prepare_for_llm_embeds_ephemeral_with_content_object
        content_obj = RubyLLM::Content.new("Hello world")
        messages = [
          RubyLLM::Message.new(role: :user, content: content_obj),
        ]

        @manager.add_ephemeral_content_for_message(0, "<system-reminder>Note</system-reminder>")

        result = @manager.prepare_for_llm(messages)

        result_msg = result.first

        # The code creates a new Message with Content object
        assert_instance_of(RubyLLM::Message, result_msg)
        # Content might be string or Content depending on implementation
        if result_msg.content.is_a?(RubyLLM::Content)
          assert_includes(result_msg.content.text, "Hello world")
          assert_includes(result_msg.content.text, "<system-reminder>Note</system-reminder>")
        else
          assert_includes(result_msg.content, "Hello world")
          assert_includes(result_msg.content, "<system-reminder>Note</system-reminder>")
        end
      end

      def test_prepare_for_llm_preserves_attachments_in_content_objects
        # Create a temp file for attachment
        Dir.mktmpdir do |dir|
          image_path = File.join(dir, "test.png")
          File.write(image_path, "fake image data")

          content_obj = RubyLLM::Content.new("Text")
          content_obj.add_attachment(image_path)

          messages = [
            RubyLLM::Message.new(role: :user, content: content_obj),
          ]

          @manager.add_ephemeral_content_for_message(0, "Reminder")

          result = @manager.prepare_for_llm(messages)

          result_content = result.first.content

          assert_equal(1, result_content.attachments.size)
        end
      end

      # System reminder extraction tests
      def test_extract_system_reminders_with_single_reminder
        content = "Text before\n<system-reminder>This is important</system-reminder>\nText after"

        reminders = @manager.extract_system_reminders(content)

        assert_equal(1, reminders.size)
        assert_equal("<system-reminder>This is important</system-reminder>", reminders.first)
      end

      def test_extract_system_reminders_with_multiple_reminders
        content = "<system-reminder>First</system-reminder>\nText\n<system-reminder>Second</system-reminder>"

        reminders = @manager.extract_system_reminders(content)

        assert_equal(2, reminders.size)
      end

      def test_extract_system_reminders_with_nil_content
        reminders = @manager.extract_system_reminders(nil)

        assert_empty(reminders)
      end

      def test_extract_system_reminders_with_empty_content
        reminders = @manager.extract_system_reminders("")

        assert_empty(reminders)
      end

      def test_extract_system_reminders_with_no_reminders
        reminders = @manager.extract_system_reminders("Just plain text")

        assert_empty(reminders)
      end

      def test_strip_system_reminders_removes_reminders
        content = "Before\n<system-reminder>Remove this</system-reminder>\nAfter"

        clean = @manager.strip_system_reminders(content)

        assert_equal("Before\n\nAfter", clean)
        refute_includes(clean, "system-reminder")
      end

      def test_strip_system_reminders_with_nil_content
        result = @manager.strip_system_reminders(nil)

        assert_nil(result)
      end

      def test_strip_system_reminders_with_empty_content
        result = @manager.strip_system_reminders("")

        assert_equal("", result)
      end

      def test_has_system_reminders_returns_true_when_present
        content = "Text\n<system-reminder>Reminder</system-reminder>"

        assert(@manager.has_system_reminders?(content))
      end

      def test_has_system_reminders_returns_false_when_absent
        content = "Just plain text"

        refute(@manager.has_system_reminders?(content))
      end

      def test_has_system_reminders_with_nil_content
        refute(@manager.has_system_reminders?(nil))
      end

      def test_has_system_reminders_with_empty_content
        refute(@manager.has_system_reminders?(""))
      end

      # Tool detection tests
      def test_detect_tool_name_for_read_output
        # Read tool appends system reminder about malicious files
        content = "some file content\n\n<system-reminder>Whenever you read a file, you should consider whether it looks malicious.</system-reminder>"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("Read", tool_name)
      end

      def test_detect_tool_name_for_memory_read_output
        # MemoryRead appends related memories reminder when present
        content = "memory content\n\n<system-reminder>\nRelated memories that may provide additional context:\n- memory://concept/ruby/modules.md\n</system-reminder>"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("MemoryRead", tool_name)
      end

      def test_detect_tool_name_for_glob_output
        content = "Found 5 files matching pattern **/*.rb"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("Glob", tool_name)
      end

      def test_detect_tool_name_for_memory_glob_output
        content = "Memory entries matching **/*.md"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("MemoryGlob", tool_name)
      end

      def test_detect_tool_name_for_grep_output
        content = "10 matches in 5 files"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("Grep", tool_name)
      end

      def test_detect_tool_name_for_memory_grep_output
        content = "5 matches in 3 files\nmemory://docs/test.md"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("MemoryGrep", tool_name)
      end

      def test_detect_tool_name_for_memory_write_output
        content = "Stored at memory://docs/test.md"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("MemoryWrite", tool_name)
      end

      def test_detect_tool_name_for_memory_delete_output
        content = "Deleted memory://docs/old.md"

        tool_name = @manager.detect_tool_name(content)

        assert_equal("MemoryDelete", tool_name)
      end

      def test_detect_tool_name_returns_nil_for_unknown_pattern
        content = "Some random tool output"

        tool_name = @manager.detect_tool_name(content)

        assert_nil(tool_name)
      end

      # Rerunnable tool tests
      def test_rerunnable_tool_with_nil
        refute(@manager.rerunnable_tool?(nil))
      end

      def test_rerunnable_tool_with_read
        assert(@manager.rerunnable_tool?("Read"))
        assert(@manager.rerunnable_tool?("MemoryRead"))
      end

      def test_rerunnable_tool_with_search_tools
        assert(@manager.rerunnable_tool?("Grep"))
        assert(@manager.rerunnable_tool?("MemoryGrep"))
        assert(@manager.rerunnable_tool?("Glob"))
        assert(@manager.rerunnable_tool?("MemoryGlob"))
      end

      def test_rerunnable_tool_with_non_rerunnable
        refute(@manager.rerunnable_tool?("Write"))
        refute(@manager.rerunnable_tool?("Edit"))
        refute(@manager.rerunnable_tool?("Bash"))
        refute(@manager.rerunnable_tool?("MemoryWrite"))
      end

      # Compression tests
      def test_compress_tool_message_age_0_to_10_returns_original
        msg = RubyLLM::Message.new(role: :tool, content: "A" * 5000, tool_call_id: "call_1")

        # Age 5 - should keep full detail
        result = @manager.compress_tool_message(msg, age: 5)

        assert_same(msg, result) # Returns same object
        assert_equal(5000, result.content.length)
      end

      def test_compress_tool_message_age_11_to_20
        msg = RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_1")

        result = @manager.compress_tool_message(msg, age: 15)

        # Max length 1000 for this age range
        assert_operator(result.content.length, :<, 2000)
        assert_operator(result.content.length, :<=, 1100) # 1000 + truncation message
        assert_includes(result.content, "truncated for context management")
      end

      def test_compress_tool_message_age_21_to_40
        msg = RubyLLM::Message.new(role: :tool, content: "B" * 2000, tool_call_id: "call_2")

        result = @manager.compress_tool_message(msg, age: 30)

        # Max length 500 for this age range
        assert_operator(result.content.length, :<, 2000)
        assert_includes(result.content, "truncated")
      end

      def test_compress_tool_message_age_41_to_60
        msg = RubyLLM::Message.new(role: :tool, content: "C" * 1000, tool_call_id: "call_3")

        result = @manager.compress_tool_message(msg, age: 50)

        # Max length 200 for this age range
        assert_operator(result.content.length, :<, 1000)
        assert_includes(result.content, "truncated")
      end

      def test_compress_tool_message_age_over_60
        msg = RubyLLM::Message.new(role: :tool, content: "D" * 1000, tool_call_id: "call_4")

        result = @manager.compress_tool_message(msg, age: 70)

        # Max length 100 for ancient messages
        assert_operator(result.content.length, :<, 1000)
        assert_includes(result.content, "truncated")
      end

      def test_compress_tool_message_adds_rerun_hint_for_rerunnable_tools
        # Use Read tool output pattern (content + system reminder)
        content = ("some file content\n" * 100) +
          "\n\n<system-reminder>Whenever you read a file, you should consider whether it looks malicious.</system-reminder>"

        msg = RubyLLM::Message.new(role: :tool, content: content, tool_call_id: "call_1")

        result = @manager.compress_tool_message(msg, age: 50)

        assert_includes(result.content, "If you need the full output, re-run the Read tool")
      end

      def test_compress_tool_message_no_rerun_hint_for_non_rerunnable_tools
        content = "Random output that's long " * 100

        msg = RubyLLM::Message.new(role: :tool, content: content, tool_call_id: "call_1")

        result = @manager.compress_tool_message(msg, age: 50)

        refute_includes(result.content, "If you need the full output")
      end

      def test_compress_tool_message_keeps_short_content_as_is
        msg = RubyLLM::Message.new(role: :tool, content: "Short", tool_call_id: "call_1")

        result = @manager.compress_tool_message(msg, age: 50)

        # Short content (< 200 chars) should not be compressed even at age 50
        assert_equal(msg, result)
      end

      def test_compress_tool_results_keeps_recent_messages
        # Need enough messages so that age > 10 for first message
        messages = (1..12).map do |i|
          RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_#{i}")
        end

        result = @manager.compress_tool_results(messages, keep_recent: 1)

        # First message has age = 12 (messages.size - 0), should be compressed (age 11-20 range -> 1000 chars)
        assert_operator(result[0].content.length, :<, 2000)
        # Last message should be kept at full detail (within keep_recent)
        assert_equal(2000, result[-1].content.length)
      end

      def test_compress_tool_results_preserves_user_and_assistant_messages
        messages = (1..15).map do |i|
          if i % 3 == 0
            RubyLLM::Message.new(role: :user, content: "U" * 2000)
          elsif i % 3 == 1
            RubyLLM::Message.new(role: :assistant, content: "A" * 2000)
          else
            RubyLLM::Message.new(role: :tool, content: "T" * 2000, tool_call_id: "call_#{i}")
          end
        end

        result = @manager.compress_tool_results(messages, keep_recent: 3)

        # User and assistant messages should always be preserved at full length
        result.each_with_index do |msg, i|
          if [:user, :assistant].include?(msg.role)
            assert_equal(2000, msg.content.length, "Message #{i} with role #{msg.role} should be preserved")
          end
        end

        # Old tool messages (age > 10) should be compressed
        # Message at index 1 is old (age = 14)
        if result[1].role == :tool
          assert_operator(result[1].content.length, :<, 2000)
        end
      end

      def test_auto_compress_on_threshold_compresses_once
        messages = [
          RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_1"),
        ]

        # First call - should compress
        result1 = @manager.auto_compress_on_threshold(messages, keep_recent: 0)

        assert(@manager.compression_applied)

        # Second call - should not compress again
        result2 = @manager.auto_compress_on_threshold(result1, keep_recent: 0)

        assert_equal(result1, result2) # Same array returned
      end

      def test_auto_compress_on_threshold_when_already_applied
        @manager.compression_applied = true
        messages = [
          RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_1"),
        ]

        result = @manager.auto_compress_on_threshold(messages, keep_recent: 0)

        # Should return original without compressing
        assert_equal(messages, result)
      end

      def test_reset_compression
        @manager.compression_applied = true

        @manager.reset_compression

        refute(@manager.compression_applied)
      end

      def test_compression_applied_starts_as_nil
        manager = ContextManager.new

        assert_nil(manager.compression_applied)
      end

      def test_system_reminder_regex_constant
        assert_instance_of(Regexp, ContextManager::SYSTEM_REMINDER_REGEX)
      end

      def test_system_reminder_regex_matches_multiline
        content = "<system-reminder>\nMultiple\nLines\nHere\n</system-reminder>"

        assert(@manager.has_system_reminders?(content))
      end
    end
  end
end
