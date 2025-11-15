# frozen_string_literal: true

require "test_helper"
require_relative "test_helper"

module SwarmSDK
  class PluginLifecycleTest < Minitest::Test
    def setup
      # Clean up Fiber scheduler before test
      Fiber.set_scheduler(nil) if Fiber.scheduler
      Fiber[:execution_id] = nil
      Fiber[:swarm_id] = nil
      Fiber[:parent_swarm_id] = nil
      Fiber[:log_callbacks] = nil

      # Set fake API key
      @original_api_key = ENV["OPENAI_API_KEY"]
      @original_max_retries = RubyLLM.config.max_retries
      @original_request_timeout = RubyLLM.config.request_timeout
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-12345"
        config.max_retries = 0
        config.request_timeout = 1
      end

      @test_scratchpad = create_test_scratchpad

      # Clear plugin registry before each test (tests are isolated)
      PluginRegistry.clear
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
        config.max_retries = @original_max_retries
        config.request_timeout = @original_request_timeout
      end
      cleanup_test_scratchpads
      cleanup_logging_state

      # Clear plugin registry (cleanup test plugins)
      PluginRegistry.clear

      # Clean up Fiber scheduler
      Fiber.set_scheduler(nil) if Fiber.scheduler
      Fiber[:execution_id] = nil
      Fiber[:swarm_id] = nil
      Fiber[:parent_swarm_id] = nil
      Fiber[:log_callbacks] = nil
    end

    # Test 1: on_swarm_started is called before execution
    def test_on_swarm_started_called_before_execution
      swarm = build_test_swarm
      plugin = TrackingPlugin.new(:test_plugin)
      PluginRegistry.register(plugin)

      stub_llm_request(mock_llm_response(content: "Test response"))

      swarm.execute("Test prompt")

      assert_includes(plugin.events, :on_swarm_started)
      assert_equal(1, plugin.events.count(:on_swarm_started))
    end

    # Test 2: on_swarm_stopped is called after execution
    def test_on_swarm_stopped_called_after_execution
      swarm = build_test_swarm
      plugin = TrackingPlugin.new(:test_plugin)
      PluginRegistry.register(plugin)

      stub_llm_request(mock_llm_response(content: "Test response"))

      swarm.execute("Test prompt")

      assert_includes(plugin.events, :on_swarm_stopped)
      assert_equal(1, plugin.events.count(:on_swarm_stopped))
    end

    # Test 3: on_swarm_stopped is called even on error
    def test_on_swarm_stopped_called_even_on_error
      swarm = build_test_swarm
      plugin = TrackingPlugin.new(:test_plugin)
      PluginRegistry.register(plugin)

      stub_llm_error(status: 500, message: "Internal server error")

      # Should not raise - errors are captured in Result
      result = swarm.execute("Test prompt")

      # Stopped hook should still be called
      assert_includes(plugin.events, :on_swarm_stopped)
      assert_equal(1, plugin.events.count(:on_swarm_stopped))
      refute_predicate(result, :success?)
    end

    # Test 4: Hooks are called in correct order
    def test_lifecycle_hooks_called_in_correct_order
      swarm = build_test_swarm
      plugin = TrackingPlugin.new(:test_plugin)
      PluginRegistry.register(plugin)

      stub_llm_request(mock_llm_response(content: "Test response"))

      swarm.execute("Test prompt")

      # Started should come before stopped
      started_index = plugin.events.index(:on_swarm_started)
      stopped_index = plugin.events.index(:on_swarm_stopped)

      assert_operator(started_index, :<, stopped_index)
    end

    # Test 5: Multiple plugins receive lifecycle events
    def test_multiple_plugins_receive_lifecycle_events
      swarm = build_test_swarm
      plugin1 = TrackingPlugin.new(:plugin1)
      plugin2 = TrackingPlugin.new(:plugin2)
      PluginRegistry.register(plugin1)
      PluginRegistry.register(plugin2)

      stub_llm_request(mock_llm_response(content: "Test response"))

      swarm.execute("Test prompt")

      # Both plugins should receive both events
      assert_includes(plugin1.events, :on_swarm_started)
      assert_includes(plugin1.events, :on_swarm_stopped)
      assert_includes(plugin2.events, :on_swarm_started)
      assert_includes(plugin2.events, :on_swarm_stopped)
    end

    # Test 6: Swarm object is passed to lifecycle hooks
    def test_swarm_object_passed_to_hooks
      swarm = build_test_swarm
      plugin = TrackingPlugin.new(:test_plugin)
      PluginRegistry.register(plugin)

      stub_llm_request(mock_llm_response(content: "Test response"))

      swarm.execute("Test prompt")

      # Check that swarm was passed
      assert_equal(swarm, plugin.started_swarm)
      assert_equal(swarm, plugin.stopped_swarm)
    end

    # Test 7: Hooks handle plugins without the method gracefully
    def test_hooks_handle_missing_methods_gracefully
      swarm = build_test_swarm
      plugin = MinimalPlugin.new(:minimal)
      PluginRegistry.register(plugin)

      stub_llm_request(mock_llm_response(content: "Test response"))

      # Should not raise even if plugin doesn't implement hooks
      result = swarm.execute("Test prompt")

      assert_predicate(result, :success?)
    end

    # Test 8: on_swarm_stopped NOT called on ConfigurationError
    # ConfigurationError happens during agent initialization, BEFORE execution starts
    # So on_swarm_started/stopped hooks are not triggered (swarm never actually started)
    def test_on_swarm_stopped_not_called_on_configuration_error
      swarm = build_test_swarm_with_missing_delegate
      plugin = TrackingPlugin.new(:test_plugin)
      PluginRegistry.register(plugin)

      stub_llm_request(mock_llm_response(content: "Test response"))

      # ConfigurationError happens during agent initialization, before execution
      error = assert_raises(ConfigurationError) do
        swarm.execute("Test prompt")
      end

      assert_match(/unknown agent/, error.message)

      # on_swarm_started/stopped should NOT be called since swarm never started
      # ConfigurationError is raised during agent initialization phase
      refute_includes(plugin.events, :on_swarm_started)
      refute_includes(plugin.events, :on_swarm_stopped)
    end

    private

    def build_test_swarm
      swarm = Swarm.new(
        name: "Plugin Lifecycle Test",
        scratchpad: @test_scratchpad,
      )

      agent_def = Agent::Definition.new(:test_agent, {
        description: "Test agent",
        model: "gpt-4",
        system_prompt: "You are a test agent",
        tools: [],
        assume_model_exists: true,
      })

      swarm.add_agent(agent_def)
      swarm.lead = :test_agent

      swarm
    end

    def build_test_swarm_with_missing_delegate
      swarm = Swarm.new(
        name: "Plugin Lifecycle Test",
        scratchpad: @test_scratchpad,
      )

      agent_def = Agent::Definition.new(:test_agent, {
        description: "Test agent",
        model: "gpt-4",
        system_prompt: "You are a test agent",
        tools: [],
        delegates_to: [:nonexistent_agent], # This will cause ConfigurationError
        assume_model_exists: true,
      })

      swarm.add_agent(agent_def)
      swarm.lead = :test_agent

      swarm
    end

    # Test plugin that tracks lifecycle events
    class TrackingPlugin < Plugin
      attr_reader :events, :started_swarm, :stopped_swarm

      def initialize(name)
        super()
        @plugin_name = name
        @events = []
        @started_swarm = nil
        @stopped_swarm = nil
      end

      def name
        @plugin_name
      end

      def tools
        []
      end

      def on_swarm_started(swarm:)
        @events << :on_swarm_started
        @started_swarm = swarm
      end

      def on_swarm_stopped(swarm:)
        @events << :on_swarm_stopped
        @stopped_swarm = swarm
      end
    end

    # Minimal plugin without lifecycle hooks
    class MinimalPlugin < Plugin
      def initialize(name)
        super()
        @plugin_name = name
      end

      def name
        @plugin_name
      end

      def tools
        []
      end

      # Intentionally does NOT implement on_swarm_started or on_swarm_stopped
    end
  end
end
