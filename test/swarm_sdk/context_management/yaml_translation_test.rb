# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module ContextManagement
    class YAMLTranslationTest < Minitest::Test
      def test_translates_compress_tool_results_action
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_60:
                    action: compress_tool_results
                    keep_recent: 15
                    truncate_to: 300
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]

        refute_nil(definition.hooks)
        assert_equal(1, definition.hooks[:context_warning].size)
      ensure
        swarm&.cleanup
      end

      def test_translates_prune_old_messages_action
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_80:
                    action: prune_old_messages
                    keep_recent: 25
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]

        refute_nil(definition.hooks[:context_warning])
      ensure
        swarm&.cleanup
      end

      def test_translates_log_warning_action
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_90:
                    action: log_warning
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]

        refute_nil(definition.hooks[:context_warning])
      ensure
        swarm&.cleanup
      end

      def test_translates_multiple_thresholds
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_60:
                    action: compress_tool_results
                    keep_recent: 10
                    truncate_to: 200
                  warning_80:
                    action: prune_old_messages
                    keep_recent: 20
                  warning_90:
                    action: log_warning
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]

        assert_equal(3, definition.hooks[:context_warning].size)
      ensure
        swarm&.cleanup
      end

      def test_defaults_keep_recent_for_compress
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_60:
                    action: compress_tool_results
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]
        hook = definition.hooks[:context_warning].first

        # The hook should have been created
        refute_nil(hook)
        refute_nil(hook.proc)
      ensure
        swarm&.cleanup
      end

      def test_raises_on_unknown_action
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_60:
                    action: unknown_action
        YAML

        swarm = SwarmSDK.load(yaml)

        # Hook is created but will raise when executed
        definition = swarm.agent_definitions[:test_agent]
        hook = definition.hooks[:context_warning].first

        # Simulate execution
        mock_chat = MockChatForYAMLTest.new
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

        assert_raises(ConfigurationError) do
          hook.proc.call(hooks_context)
        end
      ensure
        swarm&.cleanup
      end

      def test_handler_executes_compress_correctly
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_60:
                    action: compress_tool_results
                    keep_recent: 1
                    truncate_to: 50
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]
        hook = definition.hooks[:context_warning].first

        # Setup mock chat with messages
        mock_chat = MockChatForYAMLTest.new
        mock_chat.messages_data = [
          RubyLLM::Message.new(role: :tool, content: "A" * 200, tool_call_id: "old"),
          RubyLLM::Message.new(role: :tool, content: "B" * 100, tool_call_id: "recent"),
        ]

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

        # Old message should be compressed
        assert_match(/truncated/, mock_chat.messages_data.first.content)
        # Recent message should not be compressed
        refute_match(/truncated/, mock_chat.messages_data.last.content)
      ensure
        swarm&.cleanup
      end

      def test_handler_executes_prune_correctly
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
                context_management:
                  warning_80:
                    action: prune_old_messages
                    keep_recent: 2
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]
        hook = definition.hooks[:context_warning].first

        # Setup mock chat with messages
        mock_chat = MockChatForYAMLTest.new
        mock_chat.messages_data = [
          RubyLLM::Message.new(role: :system, content: "System"),
          RubyLLM::Message.new(role: :user, content: "Old"),
          RubyLLM::Message.new(role: :user, content: "Recent 1"),
          RubyLLM::Message.new(role: :user, content: "Recent 2"),
        ]

        hooks_context = Hooks::Context.new(
          event: :context_warning,
          agent_name: :test_agent,
          swarm: nil,
          metadata: {
            chat: mock_chat,
            threshold: 80, # Must match warning_80
            percentage: 85.0,
            tokens_used: 8500,
            tokens_remaining: 1500,
            context_limit: 10_000,
          },
        )

        hook.proc.call(hooks_context)

        # Should have system + 2 recent = 3 messages
        assert_equal(3, mock_chat.messages_data.size)
        assert_equal(:system, mock_chat.messages_data.first.role)
      ensure
        swarm&.cleanup
      end

      def test_no_context_management_in_yaml_means_no_hooks
        yaml = <<~YAML
          version: 2
          swarm:
            name: "Test Swarm"
            lead: test_agent
            agents:
              test_agent:
                description: "Test agent"
                model: "gpt-5"
                system_prompt: "You are a test agent"
                tools: []
        YAML

        swarm = SwarmSDK.load(yaml)

        definition = swarm.agent_definitions[:test_agent]

        # Should have no context_warning hooks
        if definition.hooks.nil?
          assert_nil(definition.hooks)
        else
          assert_nil(definition.hooks[:context_warning])
        end
      ensure
        swarm&.cleanup
      end
    end

    # Mock chat for YAML translation tests
    class MockChatForYAMLTest
      attr_accessor :messages_data

      def initialize
        @messages_data = []
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
        @context_manager ||= Agent::ContextManager.new
      end

      def respond_to?(method, include_private = false)
        [:context_manager].include?(method) || super
      end
    end
  end
end
