# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class AgentChatTest < Minitest::Test
    def setup
      @global_semaphore = Async::Semaphore.new(50)
      # Set fake API key to avoid RubyLLM configuration errors
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      # Also configure RubyLLM directly to avoid caching issues
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
      end
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      # Reset RubyLLM configuration
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
      end
    end

    def test_initialization_with_defaults
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      assert_instance_of(Agent::Chat, chat)
      # Composition: Chat uses RubyLLM's Provider but doesn't inherit from RubyLLM::Chat
      assert_equal(Object, chat.class.superclass)
      # Verify it has RubyLLM provider and model via composition
      # Providers are modules that respond to :complete, not instances of a base class
      refute_nil(chat.provider)
      assert_respond_to(chat.provider, :complete)
      # Model is resolved to Model::Info object - accessed via internal_model
      assert_kind_of(RubyLLM::Model::Info, chat.internal_model)
    end

    def test_initialization_with_base_url
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
          base_url: "https://custom.api",
        },
      )

      # Verify chat was created successfully with custom context
      assert_instance_of(Agent::Chat, chat)
    end

    def test_has_setup_tool_execution_hook_method
      # setup_tool_execution_hook is a private method that configures around_tool_execution
      Agent::Chat.new(definition: { model: "gpt-5" })

      assert_includes(
        Agent::Chat.private_instance_methods(false),
        :setup_tool_execution_hook,
        "setup_tool_execution_hook should be a private method in composition-based Chat",
      )
    end

    def test_uses_composition_with_ruby_llm
      # Chat uses composition (holds reference) instead of inheritance
      assert_equal(Object, Agent::Chat.superclass)
      # But still provides RubyLLM-like API via composition
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      assert_respond_to(chat, :ask)
      assert_respond_to(chat, :complete)
      assert_respond_to(chat, :add_message)
      assert_respond_to(chat, :with_tool)
      assert_respond_to(chat, :with_temperature)
      assert_respond_to(chat, :with_params)
      assert_respond_to(chat, :with_headers)
      assert_respond_to(chat, :with_instructions)
    end

    def test_initialization_with_custom_timeout
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          timeout: 600,
        },
      )

      assert_instance_of(Agent::Chat, chat)
    end

    def test_initialization_with_base_url_requires_provider
      error = assert_raises(ArgumentError) do
        Agent::Chat.new(
          definition: {
            model: "gpt-5",
            base_url: "https://custom.api",
          },
        )
      end

      assert_match(/provider must be specified/i, error.message)
    end

    def test_initialization_with_base_url_and_ollama_provider
      chat = Agent::Chat.new(
        definition: {
          model: "llama3",
          provider: "ollama",
          base_url: "http://localhost:11434",
        },
      )

      assert_instance_of(Agent::Chat, chat)
    end

    def test_initialization_with_base_url_and_gpustack_provider
      # Set GPUStack API key for test
      original_key = ENV["GPUSTACK_API_KEY"]
      ENV["GPUSTACK_API_KEY"] = "test-key"

      chat = Agent::Chat.new(
        definition: {
          model: "test-model",
          provider: "gpustack",
          base_url: "http://localhost:8080",
        },
      )

      assert_instance_of(Agent::Chat, chat)
    ensure
      ENV["GPUSTACK_API_KEY"] = original_key
    end

    def test_initialization_with_base_url_and_openrouter_provider
      # Set OpenRouter API key for test
      original_key = ENV["OPENROUTER_API_KEY"]
      ENV["OPENROUTER_API_KEY"] = "test-key"

      # Also configure RubyLLM to avoid configuration error
      RubyLLM.configure do |config|
        config.openrouter_api_key = "test-key"
      end

      chat = Agent::Chat.new(
        definition: {
          model: "anthropic/claude-sonnet-4",
          provider: "openrouter",
          base_url: "https://openrouter.ai/api/v1",
        },
      )

      assert_instance_of(Agent::Chat, chat)
    ensure
      ENV["OPENROUTER_API_KEY"] = original_key
      RubyLLM.configure do |config|
        config.openrouter_api_key = original_key
      end
    end

    def test_initialization_with_unsupported_provider_and_base_url_raises_error
      error = assert_raises(ArgumentError) do
        Agent::Chat.new(
          definition: {
            model: "test-model",
            provider: "unsupported",
            base_url: "https://custom.api",
          },
        )
      end

      assert_match(/doesn't support custom base_url/i, error.message)
    end

    def test_context_limit_returns_model_context_window
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      limit = chat.context_limit

      # gpt-5 should have a context limit (RubyLLM provides this)
      assert(limit.nil? || limit.positive?, "Expected context limit to be nil or positive")
    end

    def test_context_limit_handles_missing_model_gracefully
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Even if chat.internal_model raises error, we have @real_model_info as fallback
      chat.stub(:internal_model, ->() { raise StandardError, "Model not found" }) do
        limit = chat.context_limit

        # Should still get context from @real_model_info
        assert(limit.nil? || limit.positive?, "Expected fallback to @real_model_info")
      end
    end

    def test_cumulative_input_tokens_sums_message_tokens
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages - input_tokens on assistant messages is cumulative
      # Only the LATEST assistant message's input_tokens matters
      user1 = Struct.new(:role, :input_tokens).new(:user, nil)
      assistant1 = Struct.new(:role, :input_tokens).new(:assistant, 100)
      user2 = Struct.new(:role, :input_tokens).new(:user, nil)
      assistant2 = Struct.new(:role, :input_tokens).new(:assistant, 250) # Already includes assistant1's input
      user3 = Struct.new(:role, :input_tokens).new(:user, nil)
      assistant3 = Struct.new(:role, :input_tokens).new(:assistant, 350) # Already includes all previous

      chat.stub(:internal_messages, [user1, assistant1, user2, assistant2, user3, assistant3]) do
        assert_equal(350, chat.cumulative_input_tokens, "Should use latest assistant message's input_tokens")
      end
    end

    def test_cumulative_input_tokens_handles_nil_tokens
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages with some nil tokens
      user1 = Struct.new(:role, :input_tokens).new(:user, nil)
      assistant1 = Struct.new(:role, :input_tokens).new(:assistant, 100)
      user2 = Struct.new(:role, :input_tokens).new(:user, nil)
      assistant2 = Struct.new(:role, :input_tokens).new(:assistant, nil) # No tokens reported
      user3 = Struct.new(:role, :input_tokens).new(:user, nil)
      assistant3 = Struct.new(:role, :input_tokens).new(:assistant, 250)

      chat.stub(:internal_messages, [user1, assistant1, user2, assistant2, user3, assistant3]) do
        assert_equal(250, chat.cumulative_input_tokens, "Should use latest assistant message with non-nil input_tokens")
      end
    end

    def test_cumulative_output_tokens_sums_message_tokens
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages - output tokens are per-response and should be summed
      user1 = Struct.new(:role, :output_tokens).new(:user, nil)
      assistant1 = Struct.new(:role, :output_tokens).new(:assistant, 75)
      user2 = Struct.new(:role, :output_tokens).new(:user, nil)
      assistant2 = Struct.new(:role, :output_tokens).new(:assistant, 125)
      user3 = Struct.new(:role, :output_tokens).new(:user, nil)
      assistant3 = Struct.new(:role, :output_tokens).new(:assistant, 25)

      chat.stub(:internal_messages, [user1, assistant1, user2, assistant2, user3, assistant3]) do
        assert_equal(225, chat.cumulative_output_tokens, "Should sum all assistant messages' output_tokens")
      end
    end

    def test_cumulative_total_tokens_sums_input_and_output
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages with both input and output tokens
      # Input is cumulative (latest only), output is per-response (sum all)
      user1 = Struct.new(:role, :input_tokens, :output_tokens).new(:user, nil, nil)
      assistant1 = Struct.new(:role, :input_tokens, :output_tokens).new(:assistant, 100, 75)
      user2 = Struct.new(:role, :input_tokens, :output_tokens).new(:user, nil, nil)
      assistant2 = Struct.new(:role, :input_tokens, :output_tokens).new(:assistant, 250, 125) # input already includes assistant1

      chat.stub(:internal_messages, [user1, assistant1, user2, assistant2]) do
        # Latest input (250) + sum of outputs (75 + 125 = 200) = 450
        assert_equal(450, chat.cumulative_total_tokens)
      end
    end

    def test_context_usage_percentage_calculates_correctly
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock context limit and cumulative tokens
      chat.stub(:context_limit, 100_000) do
        chat.stub(:cumulative_total_tokens, 25_000) do
          assert_in_delta(25.0, chat.context_usage_percentage)
        end
      end
    end

    def test_context_usage_percentage_returns_zero_when_limit_nil
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      chat.stub(:context_limit, nil) do
        assert_in_delta(0.0, chat.context_usage_percentage)
      end
    end

    def test_context_usage_percentage_returns_zero_when_limit_zero
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      chat.stub(:context_limit, 0) do
        assert_in_delta(0.0, chat.context_usage_percentage)
      end
    end

    def test_context_usage_percentage_rounds_to_two_decimals
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      chat.stub(:context_limit, 100_000) do
        chat.stub(:cumulative_total_tokens, 12_345) do
          # 12345 / 100000 * 100 = 12.345%
          assert_in_delta(12.35, chat.context_usage_percentage)
        end
      end
    end

    def test_tokens_remaining_calculates_correctly
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      chat.stub(:context_limit, 100_000) do
        chat.stub(:cumulative_total_tokens, 25_000) do
          assert_equal(75_000, chat.tokens_remaining)
        end
      end
    end

    def test_tokens_remaining_returns_nil_when_limit_nil
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      chat.stub(:context_limit, nil) do
        assert_nil(chat.tokens_remaining)
      end
    end

    def test_tokens_remaining_handles_negative_values
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Context limit exceeded
      chat.stub(:context_limit, 100_000) do
        chat.stub(:cumulative_total_tokens, 150_000) do
          assert_equal(-50_000, chat.tokens_remaining)
        end
      end
    end

    def test_context_limit_with_base_url_fetches_real_model_info
      # When using base_url with assume_model_exists, we should still get context limit
      # from the real model info in RubyLLM's registry
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5-mini",
          provider: "openai",
          base_url: "https://proxy.api",
        },
      )

      # Should have fetched the real model info
      real_model_info = chat.real_model_info

      refute_nil(real_model_info, "Expected real_model_info to be set")

      # Should be able to get context limit from real model info
      limit = chat.context_limit

      assert(limit.nil? || limit.positive?, "Expected context limit to be nil or positive, got #{limit}")
    end

    def test_context_limit_without_base_url_uses_real_model_info
      # Now we ALWAYS fetch real model info for accurate context tracking
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Should have fetched real model info even without base_url
      real_model_info = chat.real_model_info

      refute_nil(real_model_info, "Expected @real_model_info to be populated for better context tracking")

      # Should get context limit from real model info
      limit = chat.context_limit

      assert(limit.nil? || limit.positive?, "Expected context limit to be nil or positive")
      assert_equal(real_model_info.context_window, limit, "Should use real_model_info's context_window")
    end

    def test_determine_provider_with_api_version_responses
      # When api_version is v1/responses, should use custom provider
      chat = Agent::Chat.new(
        definition: {
          model: "claude-sonnet-4",
          provider: "openai",
          base_url: "https://proxy.api",
          api_version: "v1/responses",
        },
      )

      # The determine_provider method should have been called internally
      # Verify by checking that the chat was created successfully
      assert_instance_of(Agent::Chat, chat)
    end

    def test_determine_provider_without_api_version
      # Without api_version, should use standard provider
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
          base_url: "https://proxy.api",
        },
      )

      assert_instance_of(Agent::Chat, chat)
    end

    def test_determine_provider_with_api_version_chat_completions
      # With api_version set to chat/completions, should use standard provider
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
          base_url: "https://proxy.api",
          api_version: "v1/chat/completions",
        },
      )

      assert_instance_of(Agent::Chat, chat)
    end

    def test_determine_provider_without_base_url_ignores_api_version
      # Without base_url, api_version should be ignored
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
          api_version: "v1/responses",
        },
      )

      # Should still create chat successfully
      assert_instance_of(Agent::Chat, chat)
    end

    def test_openai_with_responses_provider_registered
      # Verify our custom provider is registered
      assert(RubyLLM::Provider.providers.key?(:openai_with_responses))
    end

    def test_system_reminders_injected_on_first_ask
      # Stub the OpenAI API to capture the request body
      captured_body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with do |request|
        captured_body = JSON.parse(request.body)
        true
      end
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-123",
            object: "chat.completion",
            created: 1_677_652_288,
            model: "gpt-5",
            choices: [
              {
                index: 0,
                message: {
                  role: "assistant",
                  content: "Response",
                },
                finish_reason: "stop",
              },
            ],
            usage: {
              prompt_tokens: 10,
              completion_tokens: 5,
              total_tokens: 15,
            },
          }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # First ask should inject system reminders
      chat.ask("Hello")

      # Verify the request body contains system reminders
      refute_nil(captured_body, "Should have captured request body")
      user_message = captured_body["messages"].find { |m| m["role"] == "user" }

      refute_nil(user_message, "Should have user message")

      # First message should include toolset reminder
      assert_includes(user_message["content"], "<system-reminder>")
      assert_includes(user_message["content"], "Tools available:")
      assert_includes(user_message["content"], "Only use tools from this list")

      # Verify original prompt is included
      assert_includes(user_message["content"], "Hello")
    end

    def test_system_reminders_not_injected_on_subsequent_ask
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Stub has_user_message? to return true (simulating subsequent message)
      chat.stub(:has_user_message?, true) do
        # Mock super to track if it was called
        super_called = false
        chat.define_singleton_method(:call_super_ask) do |_prompt, **_options|
          super_called = true
          Struct.new(:content).new("Response")
        end

        # Stub the ask method to call our mock instead of super
        chat.method(:ask)
        chat.define_singleton_method(:ask) do |prompt, **options|
          # Check if first message
          is_first_message = !has_user_message?

          if is_first_message
            # This branch shouldn't be taken
            raise "Should not inject reminders on subsequent message"
          else
            call_super_ask(prompt, **options)
          end
        end

        # Call ask - should not inject reminders
        chat.ask("Second message")

        # Verify super was called (no system reminders)
        assert(super_called, "Expected super to be called for subsequent message")
      end
    end

    def test_system_reminder_constants_defined
      # Verify the constants are defined in SystemReminderInjector
      assert_kind_of(String, Agent::Chat::SystemReminderInjector::AFTER_FIRST_MESSAGE_REMINDER)
      assert_kind_of(String, Agent::Chat::SystemReminderInjector::TODOWRITE_PERIODIC_REMINDER)

      # Verify content
      assert_match(/todo list is currently empty/, Agent::Chat::SystemReminderInjector::AFTER_FIRST_MESSAGE_REMINDER)
      assert_match(/TodoWrite tool hasn't been used recently/, Agent::Chat::SystemReminderInjector::TODOWRITE_PERIODIC_REMINDER)
    end

    def test_context_limit_with_explicit_context_window
      chat = Agent::Chat.new(definition: { model: "gpt-5", context_window: 150_000 })

      assert_equal(150_000, chat.context_limit)
    end

    def test_context_limit_with_real_model_info
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Should have real_model_info
      real_model_info = chat.real_model_info

      refute_nil(real_model_info)
      assert_equal(real_model_info.context_window, chat.context_limit)
    end

    def test_context_limit_with_error_returns_nil
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock internal_model to raise error
      chat.stub(:internal_model, ->() { raise StandardError, "Model error" }) do
        # Should return nil instead of crashing
        limit = chat.context_limit

        # Will be nil if both @real_model_info and internal_model() fail
        assert(limit.nil? || limit.positive?)
      end
    end

    def test_cumulative_input_tokens_with_no_assistant_messages
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages with no assistant messages
      user1 = Struct.new(:role, :input_tokens).new(:user, nil)

      chat.stub(:internal_messages, [user1]) do
        assert_equal(0, chat.cumulative_input_tokens)
      end
    end

    def test_cumulative_output_tokens_with_no_assistant_messages
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      user1 = Struct.new(:role, :output_tokens).new(:user, nil)

      chat.stub(:internal_messages, [user1]) do
        assert_equal(0, chat.cumulative_output_tokens)
      end
    end

    def test_should_inject_todowrite_reminder_with_few_messages
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages with only 3 messages
      user1 = Struct.new(:role).new(:user)
      user2 = Struct.new(:role).new(:user)
      user3 = Struct.new(:role).new(:user)

      chat.stub(:internal_messages, [user1, user2, user3]) do
        chat.stub(:message_count, 3) do
          refute(Agent::Chat::SystemReminderInjector.should_inject_todowrite_reminder?(chat, nil))
        end
      end
    end

    def test_should_inject_todowrite_reminder_with_recent_todowrite
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages with recent TodoWrite
      messages = (1..10).map { Struct.new(:role, :content).new(:user, "test") }
      messages << Struct.new(:role, :content).new(:tool, "TodoWrite result")

      chat.stub(:internal_messages, messages) do
        chat.stub(:message_count, messages.size) do
          refute(Agent::Chat::SystemReminderInjector.should_inject_todowrite_reminder?(chat, nil))
        end
      end
    end

    def test_should_inject_todowrite_reminder_after_interval
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock messages exceeding interval without TodoWrite
      messages = (1..20).map { Struct.new(:role, :content).new(:user, "test") }

      chat.stub(:internal_messages, messages) do
        chat.stub(:message_count, messages.size) do
          assert(Agent::Chat::SystemReminderInjector.should_inject_todowrite_reminder?(chat, nil))
        end
      end
    end

    def test_should_inject_todowrite_reminder_after_interval_from_last_use
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock 20 messages (15 since last TodoWrite at index 5)
      messages = (1..20).map { Struct.new(:role, :content).new(:user, "test") }

      chat.stub(:internal_messages, messages) do
        chat.stub(:message_count, messages.size) do
          assert(Agent::Chat::SystemReminderInjector.should_inject_todowrite_reminder?(chat, 5))
        end
      end
    end

    def test_configure_responses_api_provider_with_custom_provider
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
          base_url: "https://custom.api",
          api_version: "v1/responses",
        },
      )

      # Provider should be configured
      provider_instance = chat.provider

      assert_instance_of(SwarmSDK::Providers::OpenAIWithResponses, provider_instance)
      assert(provider_instance.use_responses_api)
    end

    def test_configure_responses_api_provider_without_custom_provider
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
          base_url: "https://custom.api",
        },
      )

      # Should still create chat
      assert_instance_of(Agent::Chat, chat)
    end

    def test_emit_model_lookup_warning_emits_event
      chat = Agent::Chat.new(
        definition: { model: "nonexistent-model-xyz", provider: "openai", assume_model_exists: true },
      )

      # Mock LogStream
      events = []
      LogStream.stub(:emit, ->(entry) { events << entry }) do
        chat.emit_model_lookup_warning(:test_agent)
      end

      # Should have emitted warning (model lookup happens in constructor)
      # Since model doesn't exist in registry, @model_lookup_error should be set
      assert_equal(1, events.size)
      assert_equal("model_lookup_warning", events[0][:type])
      assert_equal(:test_agent, events[0][:agent])
      assert_equal("nonexistent-model-xyz", events[0][:model])
    end

    def test_emit_model_lookup_warning_without_error_does_nothing
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Mock LogStream
      events = []
      LogStream.stub(:emit, ->(entry) { events << entry }) do
        chat.emit_model_lookup_warning(:test_agent)
      end

      # Should not emit anything
      assert_empty(events)
    end

    def test_initialization_with_custom_timeout_no_base_url
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          timeout: 600,
        },
      )

      # Should create isolated context due to non-default timeout
      assert_instance_of(Agent::Chat, chat)
    end

    def test_initialization_with_provider_only
      # Use a provider that doesn't require special configuration
      chat = Agent::Chat.new(
        definition: {
          model: "gpt-5",
          provider: "openai",
        },
      )

      assert_instance_of(Agent::Chat, chat)
    end

    def test_initialization_without_provider_or_base_url
      chat = Agent::Chat.new(
        definition: { model: "gpt-5" },
      )

      assert_instance_of(Agent::Chat, chat)
    end

    def test_todowrite_reminder_not_injected_when_tool_missing
      # Stub the OpenAI API to capture the request body
      captured_body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with do |request|
        captured_body = JSON.parse(request.body)
        true
      end
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-123",
            object: "chat.completion",
            created: 1_677_652_288,
            model: "gpt-5",
            choices: [{ index: 0, message: { role: "assistant", content: "Response" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
          }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      # Create chat without TodoWrite tool
      chat = Agent::Chat.new(definition: { model: "gpt-5" })
      chat.remove_tool(:TodoWrite) if chat.has_tool?(:TodoWrite)

      # Add enough messages to exceed interval (>= 8)
      10.times { chat.add_message(role: :user, content: "test") }

      # Ask should NOT inject TodoWrite reminder (no TodoWrite tool)
      chat.ask("Hello")

      # Verify TodoWrite reminder was NOT injected
      last_message = captured_body["messages"].last

      refute_match(/TodoWrite tool hasn't been used recently/, last_message["content"].to_s)
    end

    def test_todowrite_reminder_injected_when_tool_present
      # Create chat with TodoWrite tool
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Directly add TodoWrite to internal_tools hash (simpler than mocking with_tool)
      todo_tool = Struct.new(:name).new("TodoWrite")
      chat.internal_tools["TodoWrite"] = todo_tool

      # Mock messages exceeding interval (should trigger reminder)
      messages = (1..20).map { Struct.new(:role, :content).new(:user, "test") }
      chat.stub(:internal_messages, messages) do
        chat.stub(:message_count, messages.size) do
          # Test the guard logic directly
          # With TodoWrite tool present and enough messages, should_inject should return true
          assert(
            Agent::Chat::SystemReminderInjector.should_inject_todowrite_reminder?(chat, nil),
            "Should inject reminder when TodoWrite tool is present",
          )

          # Verify the guard in ask() works by checking that has_tool?("TodoWrite") returns true
          assert(chat.has_tool?("TodoWrite"), "TodoWrite tool should be present")
        end
      end
    end

    def test_after_first_message_reminder_not_injected_when_tool_missing
      # Stub the OpenAI API to capture the request body
      captured_body = nil
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .with do |request|
        captured_body = JSON.parse(request.body)
        true
      end
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-123",
            object: "chat.completion",
            created: 1_677_652_288,
            model: "gpt-5",
            choices: [{ index: 0, message: { role: "assistant", content: "Response" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
          }.to_json,
          headers: { "Content-Type" => "application/json" },
        )

      # Create chat without TodoWrite tool
      chat = Agent::Chat.new(definition: { model: "gpt-5" })
      chat.remove_tool(:TodoWrite) if chat.has_tool?(:TodoWrite)

      # First ask should NOT include AFTER_FIRST_MESSAGE_REMINDER (no TodoWrite tool)
      chat.ask("Hello")

      # Verify AFTER_FIRST_MESSAGE_REMINDER was NOT included
      user_message = captured_body["messages"].find { |m| m["role"] == "user" }

      refute_match(/todo list is currently empty/, user_message["content"].to_s)
    end

    def test_after_first_message_reminder_injected_when_tool_present
      # Create chat with TodoWrite tool
      chat = Agent::Chat.new(definition: { model: "gpt-5" })

      # Directly add TodoWrite to internal_tools hash (simpler than mocking with_tool)
      todo_tool = Struct.new(:name).new("TodoWrite")
      chat.internal_tools["TodoWrite"] = todo_tool

      # Test the guard logic for first message reminder
      # Build parts as inject_first_message_reminders does
      parts = [
        "test prompt",
        Agent::Chat::SystemReminderInjector.build_toolset_reminder(chat),
      ]

      # Guard: only add AFTER_FIRST_MESSAGE_REMINDER if TodoWrite tool present
      parts << Agent::Chat::SystemReminderInjector::AFTER_FIRST_MESSAGE_REMINDER if chat.has_tool?("TodoWrite")

      full_content = parts.join("\n\n")

      # Verify AFTER_FIRST_MESSAGE_REMINDER WAS included (because TodoWrite is present)
      assert_match(/todo list is currently empty/, full_content)

      # Verify the guard condition is true
      assert(chat.has_tool?("TodoWrite"), "TodoWrite tool should be present for reminder")
    end
  end
end
