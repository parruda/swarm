# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module ContextManagement
    class AgentBuilderIntegrationTest < Minitest::Test
      def test_context_management_dsl_adds_hooks_to_definition
        builder = Agent::Builder.new(:test_agent)
        builder.context_management do
          on(:warning_60) do |ctx|
            ctx.compress_tool_results(keep_recent: 10)
          end
        end

        definition = builder.to_definition

        refute_nil(definition.hooks)
        assert_equal(1, definition.hooks[:context_warning].size)
        assert_instance_of(Hooks::Definition, definition.hooks[:context_warning].first)
      end

      def test_multiple_thresholds_create_multiple_hooks
        builder = Agent::Builder.new(:test_agent)
        builder.context_management do
          on(:warning_60) do |_ctx|
            "compress"
          end
          on(:warning_80) do |_ctx|
            "prune"
          end
          on(:warning_90) do |_ctx|
            "emergency"
          end
        end

        definition = builder.to_definition

        assert_equal(3, definition.hooks[:context_warning].size)
      end

      def test_context_management_merges_with_other_hooks
        builder = Agent::Builder.new(:test_agent)

        # Add a regular pre_tool_use hook
        builder.hook(:pre_tool_use) do |_ctx|
          "tool hook"
        end

        # Add context management hooks
        builder.context_management do
          on(:warning_60) do |_ctx|
            "context hook"
          end
        end

        definition = builder.to_definition

        assert_equal(1, definition.hooks[:pre_tool_use].size)
        assert_equal(1, definition.hooks[:context_warning].size)
      end

      def test_context_management_without_other_hooks
        builder = Agent::Builder.new(:test_agent)
        builder.context_management do
          on(:warning_80) do |_ctx|
            "only context hook"
          end
        end

        definition = builder.to_definition

        assert_kind_of(Hash, definition.hooks)
        assert_equal(1, definition.hooks.size)
        refute_nil(definition.hooks[:context_warning])
      end

      def test_no_context_management_means_no_context_warning_hooks
        builder = Agent::Builder.new(:test_agent)
        definition = builder.to_definition

        # Should have no context_warning hooks
        if definition.hooks.nil?
          assert_nil(definition.hooks)
        else
          assert_nil(definition.hooks[:context_warning])
        end
      end

      def test_hooks_are_valid_hook_definitions
        builder = Agent::Builder.new(:test_agent)
        builder.context_management do
          on(:warning_60) do |_ctx|
            "test"
          end
        end

        definition = builder.to_definition
        hook = definition.hooks[:context_warning].first

        assert_equal(:context_warning, hook.event)
        assert_nil(hook.matcher)
        assert_equal(0, hook.priority)
        refute_nil(hook.proc)
      end

      def test_full_swarm_build_dsl_integration
        swarm = SwarmSDK.build do
          name("Test Swarm")
          lead(:test_agent)

          agent(:test_agent) do
            model("gpt-5")
            description("Test agent with context management")

            context_management do
              on(:warning_60) do |ctx|
                ctx.compress_tool_results(keep_recent: 15)
              end

              on(:warning_80) do |ctx|
                ctx.prune_old_messages(keep_recent: 20)
              end
            end
          end
        end

        refute_nil(swarm)
        definition = swarm.agent_definitions[:test_agent]

        refute_nil(definition.hooks)
        assert_equal(2, definition.hooks[:context_warning].size)
      ensure
        swarm&.cleanup
      end

      def test_context_management_handler_executes_correctly
        # Create a full setup to test end-to-end
        builder = Agent::Builder.new(:test_agent)
        handler_executed = false
        received_threshold = nil

        builder.context_management do
          on(:warning_60) do |ctx|
            handler_executed = true
            received_threshold = ctx.threshold
          end
        end

        definition = builder.to_definition
        hook = definition.hooks[:context_warning].first

        # Simulate hook execution with mock context
        mock_chat = MockChatForIntegration.new
        hooks_context = Hooks::Context.new(
          event: :context_warning,
          agent_name: :test_agent,
          swarm: nil,
          metadata: {
            chat: mock_chat,
            threshold: 60,
            percentage: 65.0,
            tokens_used: 1000,
            tokens_remaining: 9000,
            context_limit: 10_000,
          },
        )

        hook.proc.call(hooks_context)

        assert(handler_executed, "Handler should be executed")
        assert_equal(60, received_threshold)
      end

      def test_handler_does_not_execute_for_wrong_threshold
        builder = Agent::Builder.new(:test_agent)
        handler_executed = false

        builder.context_management do
          on(:warning_60) do |_ctx|
            handler_executed = true
          end
        end

        definition = builder.to_definition
        hook = definition.hooks[:context_warning].first

        # Simulate hook execution with wrong threshold
        mock_chat = MockChatForIntegration.new
        hooks_context = Hooks::Context.new(
          event: :context_warning,
          agent_name: :test_agent,
          swarm: nil,
          metadata: {
            chat: mock_chat,
            threshold: 80, # Different threshold
            percentage: 85.0,
            tokens_used: 1000,
            tokens_remaining: 9000,
            context_limit: 10_000,
          },
        )

        hook.proc.call(hooks_context)

        refute(handler_executed, "Handler should NOT execute for wrong threshold")
      end
    end

    # Minimal mock for integration tests
    class MockChatForIntegration
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
