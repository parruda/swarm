# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module ContextManagement
    class BuilderTest < Minitest::Test
      def test_on_warning_60_registers_handler
        builder = Builder.new
        builder.on(:warning_60, &:compress_tool_results)

        hooks = builder.build

        assert_equal(1, hooks.size)
        assert_equal(:context_warning, hooks.first.event)
      end

      def test_on_warning_80_registers_handler
        builder = Builder.new
        builder.on(:warning_80, &:prune_old_messages)

        hooks = builder.build

        assert_equal(1, hooks.size)
        assert_equal(:context_warning, hooks.first.event)
      end

      def test_on_warning_90_registers_handler
        builder = Builder.new
        builder.on(:warning_90) { |ctx| ctx.log_action("critical") }

        hooks = builder.build

        assert_equal(1, hooks.size)
        assert_equal(:context_warning, hooks.first.event)
      end

      def test_multiple_thresholds_create_multiple_hooks
        builder = Builder.new
        builder.on(:warning_60) { |_ctx| "compress" }
        builder.on(:warning_80) { |_ctx| "prune" }
        builder.on(:warning_90) { |_ctx| "emergency" }

        hooks = builder.build

        assert_equal(3, hooks.size)
        hooks.each { |h| assert_equal(:context_warning, h.event) }
      end

      def test_raises_on_unknown_event
        builder = Builder.new

        error = assert_raises(ArgumentError) do
          builder.on(:warning_50) { |_ctx| "invalid" }
        end

        assert_match(/Unknown event/, error.message)
        assert_match(/warning_50/, error.message)
        assert_match(/warning_60/, error.message)
      end

      def test_raises_without_block
        builder = Builder.new

        error = assert_raises(ArgumentError) do
          builder.on(:warning_60)
        end

        assert_match(/Block required/, error.message)
      end

      def test_hooks_have_nil_matcher
        builder = Builder.new
        builder.on(:warning_60) { |_ctx| "test" }

        hooks = builder.build

        assert_nil(hooks.first.matcher)
      end

      def test_hooks_have_zero_priority
        builder = Builder.new
        builder.on(:warning_60) { |_ctx| "test" }

        hooks = builder.build

        assert_equal(0, hooks.first.priority)
      end

      def test_hook_proc_wraps_user_block
        builder = Builder.new
        user_block_called = false
        builder.on(:warning_60) { |_ctx| user_block_called = true }

        hooks = builder.build

        # Verify proc is created
        refute_nil(hooks.first.proc)
      end

      def test_event_map_has_all_thresholds
        assert_equal(60, Builder::EVENT_MAP[:warning_60])
        assert_equal(80, Builder::EVENT_MAP[:warning_80])
        assert_equal(90, Builder::EVENT_MAP[:warning_90])
      end

      def test_empty_builder_returns_empty_array
        builder = Builder.new
        hooks = builder.build

        assert_empty(hooks)
      end

      def test_threshold_matcher_only_executes_for_matching_threshold
        builder = Builder.new
        executed = false
        builder.on(:warning_60) { |_ctx| executed = true }

        hooks = builder.build
        hook_proc = hooks.first.proc

        # Create mock hooks context for 60% threshold
        hooks_context_60 = create_mock_hooks_context(threshold: 60)
        hook_proc.call(hooks_context_60)

        assert(executed, "Should execute for matching threshold")

        # Reset and test non-matching threshold
        executed = false
        hooks_context_80 = create_mock_hooks_context(threshold: 80)
        hook_proc.call(hooks_context_80)

        refute(executed, "Should not execute for non-matching threshold")
      end

      def test_threshold_matcher_wraps_in_rich_context
        builder = Builder.new
        received_context = nil
        builder.on(:warning_60) { |ctx| received_context = ctx }

        hooks = builder.build
        hook_proc = hooks.first.proc

        # Mock chat and hooks context
        mock_chat = MockChatForContext.new
        hooks_context = create_mock_hooks_context(threshold: 60, chat: mock_chat)
        hook_proc.call(hooks_context)

        assert_instance_of(Context, received_context)
      end

      private

      def create_mock_hooks_context(threshold:, chat: nil)
        chat ||= MockChatForContext.new

        Hooks::Context.new(
          event: :context_warning,
          agent_name: :test_agent,
          swarm: nil,
          metadata: {
            chat: chat,
            threshold: threshold,
            percentage: 65.0,
            tokens_used: 1000,
            tokens_remaining: 9000,
            context_limit: 10_000,
          },
        )
      end
    end

    # Minimal mock chat for testing
    class MockChatForContext
      def messages
        []
      end

      def message_count
        0
      end

      def replace_messages(_msgs)
        self
      end

      def context_manager
        nil
      end
    end
  end
end
