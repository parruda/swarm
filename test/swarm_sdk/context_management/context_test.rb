# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module ContextManagement
    class ContextTest < Minitest::Test
      def setup
        @events = []
        @emitter = TestEventEmitter.new(@events)
        LogStream.emitter = @emitter

        @mock_chat = MockChatForContextTest.new
        @context_manager = Agent::ContextManager.new
        @mock_chat.context_manager_instance = @context_manager

        @hooks_context = Hooks::Context.new(
          event: :context_warning,
          agent_name: :test_agent,
          swarm: nil,
          metadata: {
            chat: @mock_chat,
            threshold: 60,
            percentage: 65.5,
            tokens_used: 6550,
            tokens_remaining: 3450,
            context_limit: 10_000,
          },
        )

        @context = Context.new(@hooks_context)
      end

      def teardown
        LogStream.emitter = nil
        @events.clear
      end

      # --- Context Metrics Tests ---

      def test_usage_percentage_returns_percentage
        assert_in_delta(65.5, @context.usage_percentage, 0.01)
      end

      def test_threshold_returns_threshold
        assert_equal(60, @context.threshold)
      end

      def test_tokens_used_returns_tokens_used
        assert_equal(6550, @context.tokens_used)
      end

      def test_tokens_remaining_returns_tokens_remaining
        assert_equal(3450, @context.tokens_remaining)
      end

      def test_context_limit_returns_context_limit
        assert_equal(10_000, @context.context_limit)
      end

      def test_agent_name_returns_agent_name
        assert_equal(:test_agent, @context.agent_name)
      end

      # --- Message Access Tests ---

      def test_messages_returns_chat_messages
        expected = [RubyLLM::Message.new(role: :user, content: "test")]
        @mock_chat.messages_data = expected

        assert_equal(expected, @context.messages)
      end

      def test_message_count_returns_count
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :user, content: "1"),
          RubyLLM::Message.new(role: :user, content: "2"),
        ]

        assert_equal(2, @context.message_count)
      end

      # --- Message Manipulation Tests ---

      def test_replace_messages_replaces_messages
        new_msgs = [RubyLLM::Message.new(role: :user, content: "new")]

        @context.replace_messages(new_msgs)

        assert_equal(new_msgs, @mock_chat.messages_data)
      end

      def test_compress_tool_results_compresses_old_results
        # Setup messages with old tool results
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :system, content: "System"),
          RubyLLM::Message.new(role: :user, content: "User"),
          RubyLLM::Message.new(role: :tool, content: "A" * 500, tool_call_id: "old_1"),
          RubyLLM::Message.new(role: :tool, content: "B" * 500, tool_call_id: "old_2"),
          RubyLLM::Message.new(role: :tool, content: "C" * 100, tool_call_id: "recent"),
        ]

        compressed_count = @context.compress_tool_results(keep_recent: 1, truncate_to: 100)

        assert_equal(2, compressed_count)

        # Check old messages are compressed
        msgs = @mock_chat.messages_data

        assert_match(/truncated for context management/, msgs[2].content)
        assert_match(/truncated for context management/, msgs[3].content)
        # Recent one should not be compressed
        refute_match(/truncated/, msgs[4].content)
      end

      def test_compress_tool_results_skips_short_content
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :tool, content: "short", tool_call_id: "1"),
        ]

        compressed_count = @context.compress_tool_results(keep_recent: 0, truncate_to: 100)

        assert_equal(0, compressed_count)
      end

      def test_compress_tool_results_marks_compression_applied
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :tool, content: "A" * 500, tool_call_id: "1"),
        ]

        @context.compress_tool_results(keep_recent: 0, truncate_to: 100)

        assert(@context_manager.compression_applied)
      end

      def test_mark_compression_applied_sets_flag
        @context.mark_compression_applied

        assert(@context_manager.compression_applied)
      end

      def test_compression_applied_returns_flag_state
        refute_predicate(@context, :compression_applied?)

        @context_manager.compression_applied = true

        assert_predicate(@context, :compression_applied?)
      end

      def test_prune_old_messages_keeps_recent
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :system, content: "System"),
          RubyLLM::Message.new(role: :user, content: "Old 1"),
          RubyLLM::Message.new(role: :user, content: "Old 2"),
          RubyLLM::Message.new(role: :user, content: "Recent 1"),
          RubyLLM::Message.new(role: :user, content: "Recent 2"),
        ]

        removed = @context.prune_old_messages(keep_recent: 2)

        assert_equal(2, removed)
        assert_equal(3, @mock_chat.messages_data.size) # System + 2 recent
        assert_equal(:system, @mock_chat.messages_data.first.role)
        assert_equal("Recent 1", @mock_chat.messages_data[1].content)
      end

      def test_prune_old_messages_preserves_system_message
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :system, content: "Important system prompt"),
          RubyLLM::Message.new(role: :user, content: "Old"),
          RubyLLM::Message.new(role: :user, content: "Recent"),
        ]

        @context.prune_old_messages(keep_recent: 1)

        assert_equal(:system, @mock_chat.messages_data.first.role)
        assert_equal("Important system prompt", @mock_chat.messages_data.first.content)
      end

      def test_prune_old_messages_returns_zero_when_nothing_to_prune
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :user, content: "Only one"),
        ]

        removed = @context.prune_old_messages(keep_recent: 10)

        assert_equal(0, removed)
      end

      def test_summarize_old_exchanges_returns_zero
        # Placeholder implementation
        result = @context.summarize_old_exchanges(older_than: 10)

        assert_equal(0, result)
      end

      def test_transform_messages_applies_block
        @mock_chat.messages_data = [
          RubyLLM::Message.new(role: :user, content: "lowercase"),
        ]

        @context.transform_messages do |msgs|
          msgs.map do |m|
            RubyLLM::Message.new(role: m.role, content: m.content.upcase)
          end
        end

        assert_equal("LOWERCASE", @mock_chat.messages_data.first.content)
      end

      def test_log_action_emits_event
        @context.log_action("test_action", count: 5, details: "extra")

        assert_equal(1, @events.size)
        event = @events.first

        assert_equal("context_management_action", event[:type])
        assert_equal(:test_agent, event[:agent])
        assert_equal(60, event[:threshold])
        assert_equal("test_action", event[:action])
        assert_in_delta(65.5, event[:usage_percentage], 0.01)
        assert_equal(5, event[:count])
        assert_equal("extra", event[:details])
      end

      def test_log_action_works_without_details
        @context.log_action("simple_action")

        assert_equal(1, @events.size)
        assert_equal("simple_action", @events.first[:action])
      end
    end

    # Test event emitter
    class TestEventEmitter
      def initialize(events)
        @events = events
      end

      def emit(event)
        @events << event
      end
    end

    # Mock chat for context testing
    class MockChatForContextTest
      attr_accessor :messages_data, :context_manager_instance

      def initialize
        @messages_data = []
        @context_manager_instance = nil
      end

      def messages
        @messages_data.dup
      end

      def message_count
        @messages_data.size
      end

      def replace_messages(new_msgs)
        @messages_data = new_msgs
        self
      end

      def context_manager
        @context_manager_instance
      end

      def respond_to?(method, include_private = false)
        [:context_manager].include?(method) || super
      end
    end
  end
end
