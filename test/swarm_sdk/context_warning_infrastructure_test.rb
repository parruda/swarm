# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Tests for the context warning infrastructure
  #
  # These tests verify that:
  # 1. Context warnings are triggered at appropriate thresholds (60%, 80%, 90%)
  # 2. Proper events are emitted (context_threshold_hit, context_limit_warning)
  # 3. Automatic compression happens at 60% threshold (when no custom handler)
  # 4. Custom handlers can override auto-compression
  # 5. Thresholds fire only once per session
  # 6. ContextManager compression_applied flag is properly coordinated
  class ContextWarningInfrastructureTest < Minitest::Test
    def setup
      @events = []
      @emitter = TestEmitter.new(@events)
      LogStream.emitter = @emitter

      # Create a mock chat with context tracking capabilities
      @agent_context = Agent::Context.new(
        name: :test_agent,
        swarm_id: "test-swarm-id",
        delegation_tools: [],
      )

      @context_manager = Agent::ContextManager.new

      # Mock chat that includes HookIntegration
      @chat = MockChatWithHooks.new(
        agent_context: @agent_context,
        context_manager: @context_manager,
      )

      # Setup hooks system
      registry = Hooks::Registry.new
      agent_definition = Agent::Definition.new(:test_agent, {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "You are a test agent",
        tools: [],
      })

      @chat.setup_hooks(registry: registry, agent_definition: agent_definition, swarm: nil)
    end

    def teardown
      LogStream.emitter = nil
      @events.clear
    end

    def test_context_threshold_hit_events_emitted_at_60_percent
      @chat.mock_context_usage = 65.0

      @chat.check_context_warnings

      threshold_events = @events.select { |e| e[:type] == "context_threshold_hit" }

      assert_equal(1, threshold_events.size)
      assert_equal(60, threshold_events.first[:threshold])
      assert_equal(:test_agent, threshold_events.first[:agent])
      assert_in_delta(65.0, threshold_events.first[:current_usage_percentage], 0.01)
    end

    def test_context_threshold_hit_events_emitted_at_80_percent
      @chat.mock_context_usage = 85.0

      @chat.check_context_warnings

      threshold_events = @events.select { |e| e[:type] == "context_threshold_hit" }
      thresholds = threshold_events.map { |e| e[:threshold] }.sort

      assert_equal([60, 80], thresholds)
    end

    def test_context_threshold_hit_events_emitted_at_90_percent
      @chat.mock_context_usage = 95.0

      @chat.check_context_warnings

      threshold_events = @events.select { |e| e[:type] == "context_threshold_hit" }
      thresholds = threshold_events.map { |e| e[:threshold] }.sort

      assert_equal([60, 80, 90], thresholds)
    end

    def test_context_limit_warning_events_emitted
      @chat.mock_context_usage = 65.0

      @chat.check_context_warnings

      warning_events = @events.select { |e| e[:type] == "context_limit_warning" }

      assert_equal(1, warning_events.size)

      event = warning_events.first

      assert_equal(:test_agent, event[:agent])
      assert_equal("60%", event[:threshold])
      assert_equal("65.0%", event[:current_usage])
      assert_equal(1000, event[:tokens_used])
      assert_equal(9000, event[:tokens_remaining])
      assert_equal(10_000, event[:context_limit])
    end

    def test_automatic_compression_at_60_percent_threshold
      @chat.mock_context_usage = 65.0

      # Add some tool messages to compress
      messages = [
        RubyLLM::Message.new(role: :system, content: "System prompt"),
        RubyLLM::Message.new(role: :user, content: "User message"),
        RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_1"),
      ]
      @chat.messages_to_return = messages

      @chat.check_context_warnings

      # Should have compression event
      compression_events = @events.select { |e| e[:type] == "context_compression" }

      assert_equal(1, compression_events.size)
      assert_equal("auto_compression_threshold", compression_events.first[:triggered_by])

      # ContextManager should be marked as compressed
      assert(@context_manager.compression_applied)
    end

    def test_compression_applied_flag_set_after_auto_compression
      @chat.mock_context_usage = 65.0

      refute(@context_manager.compression_applied)

      @chat.check_context_warnings

      assert(@context_manager.compression_applied)
    end

    def test_warning_threshold_hit_only_once_per_session
      @chat.mock_context_usage = 65.0

      # First call triggers 60% threshold
      @chat.check_context_warnings

      events_count = @events.size

      # Second call should not trigger again
      @chat.check_context_warnings

      assert_equal(events_count, @events.size, "Threshold should not fire twice")
    end

    def test_multiple_thresholds_fire_independently
      # First trigger 60%
      @chat.mock_context_usage = 65.0
      @chat.check_context_warnings
      first_count = @events.select { |e| e[:type] == "context_threshold_hit" }.size

      # Then trigger 80%
      @chat.mock_context_usage = 85.0
      @chat.check_context_warnings
      second_count = @events.select { |e| e[:type] == "context_threshold_hit" }.size

      assert_equal(1, first_count)
      assert_equal(2, second_count) # 60% already hit, so only 80% fires
    end

    def test_no_events_when_below_threshold
      @chat.mock_context_usage = 50.0

      @chat.check_context_warnings

      assert_empty(@events)
    end

    def test_custom_handler_prevents_auto_compression
      # Add a custom context_warning hook
      @chat.add_hook(:context_warning) do |_ctx|
        # Custom handler that does nothing
      end

      @chat.mock_context_usage = 65.0
      messages = [
        RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_1"),
      ]
      @chat.messages_to_return = messages

      @chat.check_context_warnings

      # Should NOT have auto-compression event
      compression_events = @events.select { |e| e[:type] == "context_compression" }

      assert_empty(compression_events, "Custom handler should prevent auto-compression")

      # ContextManager should NOT be marked as compressed by auto-compression
      refute(@context_manager.compression_applied)
    end

    def test_context_warning_hook_receives_proper_context
      received_context = nil

      @chat.add_hook(:context_warning) do |ctx|
        received_context = ctx
      end

      @chat.mock_context_usage = 65.0
      @chat.check_context_warnings

      refute_nil(received_context)
      assert_equal(:context_warning, received_context.event)
      assert_equal(:test_agent, received_context.agent_name)
      assert_equal(60, received_context.metadata[:threshold])
      assert_in_delta(65.0, received_context.metadata[:percentage], 0.01)
      assert_equal(1000, received_context.metadata[:tokens_used])
      assert_equal(9000, received_context.metadata[:tokens_remaining])
      assert_equal(10_000, received_context.metadata[:context_limit])
      assert_equal(@chat, received_context.metadata[:chat])
    end

    def test_hook_can_modify_messages_via_chat
      @chat.add_hook(:context_warning) do |ctx|
        chat = ctx.metadata[:chat]
        msgs = chat.messages.dup
        # Simulate compression by truncating
        msgs.map! do |m|
          if m.role == :tool && m.content.to_s.length > 100
            RubyLLM::Message.new(
              role: :tool,
              content: "#{m.content.to_s[0..100]}... [compressed]",
              tool_call_id: m.tool_call_id,
            )
          else
            m
          end
        end
        chat.replace_messages(msgs)
      end

      messages = [
        RubyLLM::Message.new(role: :tool, content: "A" * 2000, tool_call_id: "call_1"),
      ]
      @chat.messages_to_return = messages
      @chat.mock_context_usage = 65.0

      @chat.check_context_warnings

      # Messages should have been modified
      assert(@chat.messages_replaced, "Hook should have replaced messages")
    end

    def test_agentcontext_warning_thresholds_hit_tracking
      @chat.mock_context_usage = 95.0

      @chat.check_context_warnings

      assert(@agent_context.warning_threshold_hit?(60))
      assert(@agent_context.warning_threshold_hit?(80))
      assert(@agent_context.warning_threshold_hit?(90))
      refute(@agent_context.warning_threshold_hit?(100))
    end
  end

  # Simple test emitter for capturing events
  class TestEmitter
    def initialize(events)
      @events = events
    end

    def emit(event)
      @events << event
    end
  end

  # Mock chat that includes HookIntegration behavior
  class MockChatWithHooks
    include Agent::ChatHelpers::HookIntegration

    attr_accessor :mock_context_usage, :messages_to_return, :messages_replaced
    attr_reader :agent_context, :context_manager, :hook_executor, :hook_agent_hooks

    def initialize(agent_context:, context_manager:)
      @agent_context = agent_context
      @context_manager = context_manager
      @mock_context_usage = 0.0
      @messages_to_return = []
      @messages_replaced = false
      @hook_agent_hooks = {}
    end

    # Override setup_hooks to track agent_hooks
    def setup_hooks(registry:, agent_definition:, swarm: nil)
      @hook_registry = registry
      @hook_swarm = swarm
      @hook_executor = Hooks::Executor.new(registry, logger: RubyLLM.logger)

      hooks = agent_definition.hooks || {}
      @hook_agent_hooks = if hooks.is_a?(Hash) && hooks.values.all? { |v| v.is_a?(Array) && v.all? { |item| item.is_a?(Hooks::Definition) } }
        hooks
      else
        {}
      end
    end

    # Context usage methods
    def context_usage_percentage
      @mock_context_usage
    end

    def cumulative_total_tokens
      1000
    end

    def tokens_remaining
      9000
    end

    def context_limit
      10_000
    end

    def model_id
      "gpt-5"
    end

    # Message methods
    def messages
      @messages_to_return.dup
    end

    def message_count
      @messages_to_return.size
    end

    def replace_messages(new_messages)
      @messages_to_return = new_messages
      @messages_replaced = true
      self
    end
  end
end
