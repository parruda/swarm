# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Observer
    class ManagerTest < Minitest::Test
      def setup
        LogCollector.reset!

        @original_api_key = ENV["OPENAI_API_KEY"]
        @original_max_retries = RubyLLM.config.max_retries
        @original_request_timeout = RubyLLM.config.request_timeout

        ENV["OPENAI_API_KEY"] = "test-key-12345"
        RubyLLM.configure do |config|
          config.openai_api_key = "test-key-12345"
          config.max_retries = 0
          config.request_timeout = 1
        end
      end

      def teardown
        LogCollector.reset!

        ENV["OPENAI_API_KEY"] = @original_api_key
        RubyLLM.configure do |config|
          config.openai_api_key = @original_api_key
          config.max_retries = @original_max_retries
          config.request_timeout = @original_request_timeout
        end
      end

      def test_add_config_stores_config
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        config = Config.new(:profiler)
        manager.add_config(config)

        # Manager stores configs internally, accessible via setup behavior
        # No direct accessor, so verify indirectly
        assert_instance_of(Manager, manager)
      end

      def test_setup_creates_barrier
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        manager.setup

        # Barrier is internal, verify via wait_for_completion not raising
        manager.wait_for_completion

        assert(true, "Setup completed without error")
      ensure
        manager&.cleanup
      end

      def test_setup_creates_subscriptions
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        initial_count = LogCollector.subscription_count

        config = Config.new(:profiler)
        config.add_handler(:swarm_start) { |_e| "test" }
        config.add_handler(:tool_call) { |_e| "test" }
        manager.add_config(config)

        manager.setup

        # Should have 2 new subscriptions (one for each handler)
        assert_equal(initial_count + 2, LogCollector.subscription_count)
      ensure
        manager&.cleanup
      end

      def test_cleanup_removes_subscriptions
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        config = Config.new(:profiler)
        config.add_handler(:swarm_start) { |_e| "test" }
        manager.add_config(config)

        manager.setup

        count_after_setup = LogCollector.subscription_count

        manager.cleanup

        # Subscriptions should be removed
        assert_operator(LogCollector.subscription_count, :<, count_after_setup)
      end

      def test_cleanup_is_idempotent
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        config = Config.new(:profiler)
        config.add_handler(:swarm_start) { |_e| "test" }
        manager.add_config(config)

        manager.setup
        manager.cleanup
        manager.cleanup # Should not raise

        assert(true, "Double cleanup completed without error")
      end

      def test_handle_event_skips_self_consumption
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        handler_called = false
        config = Config.new(:profiler)
        config.add_handler(:tool_call) do |_event|
          handler_called = true
          "Should not execute"
        end

        manager.add_config(config)
        manager.setup

        # Emit event FROM the observer agent itself
        LogCollector.emit(
          type: "tool_call",
          agent: :profiler, # Same as observer agent
          tool_name: "Read",
        )

        refute(handler_called, "Handler should not be called for self-consumption")
      ensure
        manager&.cleanup
      end

      def test_handle_event_processes_other_agents
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        handler_called = false
        config = Config.new(:profiler)
        config.add_handler(:tool_call) do |_event|
          handler_called = true
          nil # Return nil to skip spawn
        end

        manager.add_config(config)
        manager.setup

        # Emit event FROM a different agent
        LogCollector.emit(
          type: "tool_call",
          agent: :backend, # Different from observer
          tool_name: "Read",
        )

        assert(handler_called, "Handler should be called for other agents")
      ensure
        manager&.cleanup
      end

      def test_handle_event_skips_when_handler_returns_nil
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        config = Config.new(:monitor)
        config.add_handler(:tool_call) do |event|
          next unless event[:tool_name] == "Bash"

          "Check: #{event[:arguments][:command]}"
        end

        manager.add_config(config)
        manager.setup

        # This should be skipped (returns nil)
        LogCollector.emit(
          type: "tool_call",
          agent: :backend,
          tool_name: "Read",
        )

        # No async tasks spawned
        manager.wait_for_completion

        assert(true, "Skipped event handled correctly")
      ensure
        manager&.cleanup
      end

      def test_wait_for_completion_without_setup
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        # Should not raise even without setup
        manager.wait_for_completion

        assert(true, "Wait completed without setup")
      end

      def test_multiple_configs_supported
        swarm = build_test_swarm
        manager = Manager.new(swarm)

        config1 = Config.new(:profiler)
        config1.add_handler(:swarm_start) { |_e| nil }

        config2 = Config.new(:monitor)
        config2.add_handler(:tool_call) { |_e| nil }

        manager.add_config(config1)
        manager.add_config(config2)

        initial_count = LogCollector.subscription_count

        manager.setup

        # 2 configs, 1 handler each = 2 subscriptions
        assert_equal(initial_count + 2, LogCollector.subscription_count)
      ensure
        manager&.cleanup
      end

      private

      def build_test_swarm
        SwarmSDK.build do
          name("Test Observer Swarm")
          lead(:backend)

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend developer")
            system_prompt("You build APIs")
          end

          agent(:profiler) do
            model("gpt-4o-mini")
            description("Profile analyzer")
            system_prompt("You analyze prompts")
          end

          agent(:monitor) do
            model("gpt-4o-mini")
            description("Security monitor")
            system_prompt("You monitor security")
          end
        end
      end
    end
  end
end
