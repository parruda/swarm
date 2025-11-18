# frozen_string_literal: true

require "test_helper"
require_relative "../test_helper"

module SwarmSDK
  module Observer
    class IntegrationTest < Minitest::Test
      include LLMMockHelper

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
        cleanup_logging_state

        ENV["OPENAI_API_KEY"] = @original_api_key
        RubyLLM.configure do |config|
          config.openai_api_key = @original_api_key
          config.max_retries = @original_max_retries
          config.request_timeout = @original_request_timeout
        end
      end

      # Builder DSL Tests

      def test_observer_dsl_configures_swarm
        swarm = SwarmSDK.build do
          name("Observer Test Swarm")
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

          observer(:profiler) do
            on(:swarm_start) { |event| "Analyze: #{event[:prompt]}" }
          end
        end

        assert_equal(1, swarm.observer_configs.size)
        assert_equal(:profiler, swarm.observer_configs.first.agent_name)
      end

      def test_observer_dsl_with_multiple_handlers
        swarm = SwarmSDK.build do
          name("Multi-Handler Observer")
          lead(:backend)

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend")
            system_prompt("Build APIs")
          end

          agent(:monitor) do
            model("gpt-4o-mini")
            description("Monitor")
            system_prompt("Monitor things")
          end

          observer(:monitor) do
            on(:tool_call) { |_e| "Check tool" }
            on(:tool_result) { |_e| "Check result" }
            on(:agent_stop) { |_e| "Check stop" }
          end
        end

        config = swarm.observer_configs.first

        assert_equal(3, config.event_handlers.size)
        assert(config.event_handlers.key?(:tool_call))
        assert(config.event_handlers.key?(:tool_result))
        assert(config.event_handlers.key?(:agent_stop))
      end

      def test_observer_dsl_with_options
        swarm = SwarmSDK.build do
          name("Observer with Options")
          lead(:backend)

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend")
            system_prompt("Build")
          end

          agent(:profiler) do
            model("gpt-4o-mini")
            description("Profiler")
            system_prompt("Analyze")
          end

          observer(:profiler, timeout: 120) do
            on(:swarm_start) { |_e| "test" }
            max_concurrent(5)
            wait_for_completion!
          end
        end

        config = swarm.observer_configs.first

        assert_equal(120, config.options[:timeout])
        assert_equal(5, config.options[:max_concurrent])
        refute(config.options[:fire_and_forget])
      end

      def test_observer_dsl_multiple_observers
        swarm = SwarmSDK.build do
          name("Multiple Observers")
          lead(:backend)

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend")
            system_prompt("Build")
          end

          agent(:profiler) do
            model("gpt-4o-mini")
            description("Profiler")
            system_prompt("Analyze")
          end

          agent(:monitor) do
            model("gpt-4o-mini")
            description("Monitor")
            system_prompt("Monitor")
          end

          observer(:profiler) do
            on(:swarm_start) { |event| "Profile: #{event[:prompt]}" }
          end

          observer(:monitor) do
            on(:tool_call) { |event| "Monitor: #{event[:tool_name]}" }
          end
        end

        assert_equal(2, swarm.observer_configs.size)
        assert_equal(:profiler, swarm.observer_configs[0].agent_name)
        assert_equal(:monitor, swarm.observer_configs[1].agent_name)
      end

      def test_observer_dsl_raises_for_undefined_agent
        error = assert_raises(ConfigurationError) do
          SwarmSDK.build do
            name("Invalid Observer")
            lead(:backend)

            agent(:backend) do
              model("gpt-4o-mini")
              description("Backend")
              system_prompt("Build")
            end

            # Try to use undefined agent as observer
            observer(:undefined_agent) do
              on(:swarm_start) { |_e| "test" }
            end
          end
        end

        assert_match(/not defined/, error.message)
        assert_match(/undefined_agent/, error.message)
      end

      def test_observer_dsl_with_filtering_logic
        swarm = SwarmSDK.build do
          name("Filtering Observer")
          lead(:backend)

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend")
            system_prompt("Build")
          end

          agent(:security) do
            model("gpt-4o-mini")
            description("Security")
            system_prompt("Monitor security")
          end

          observer(:security) do
            on(:tool_call) do |event|
              # Ruby filtering logic
              next unless event[:tool_name] =~ /Bash|Write/

              case event[:tool_name]
              when "Bash"
                "Check bash: #{event[:arguments][:command]}"
              when "Write"
                "Check write: #{event[:arguments][:content]}"
              end
            end
          end
        end

        config = swarm.observer_configs.first
        handler = config.event_handlers[:tool_call]

        # Test filtering logic
        bash_result = handler.call(tool_name: "Bash", arguments: { command: "ls" })

        assert_equal("Check bash: ls", bash_result)

        read_result = handler.call(tool_name: "Read", arguments: {})

        assert_nil(read_result)
      end

      # Swarm Integration Tests

      def test_swarm_add_observer_config
        swarm = Swarm.new(name: "Test Swarm")

        backend_def = Agent::Definition.new(:backend, {
          description: "Backend",
          model: "gpt-4o-mini",
          system_prompt: "Build APIs",
        })
        swarm.add_agent(backend_def)

        profiler_def = Agent::Definition.new(:profiler, {
          description: "Profiler",
          model: "gpt-4o-mini",
          system_prompt: "Analyze",
        })
        swarm.add_agent(profiler_def)

        config = Config.new(:profiler)
        config.add_handler(:swarm_start) { |_e| "test" }

        swarm.add_observer_config(config)

        assert_equal(1, swarm.observer_configs.size)
      end

      def test_swarm_add_observer_config_validates_agent_exists
        swarm = Swarm.new(name: "Test Swarm")

        backend_def = Agent::Definition.new(:backend, {
          description: "Backend",
          model: "gpt-4o-mini",
          system_prompt: "Build APIs",
        })
        swarm.add_agent(backend_def)

        config = Config.new(:nonexistent)
        config.add_handler(:swarm_start) { |_e| "test" }

        error = assert_raises(ConfigurationError) do
          swarm.add_observer_config(config)
        end

        assert_match(/not found/, error.message)
      end

      def test_swarm_wait_for_observers_without_manager
        swarm = Swarm.new(name: "Test Swarm")

        # Should not raise even without observer manager
        swarm.wait_for_observers

        assert(true, "wait_for_observers handles nil manager")
      end

      def test_swarm_cleanup_observers_without_manager
        swarm = Swarm.new(name: "Test Swarm")

        # Should not raise even without observer manager
        swarm.cleanup_observers

        assert(true, "cleanup_observers handles nil manager")
      end

      def test_swarm_execute_sets_up_observer_manager
        swarm = SwarmSDK.build do
          name("Observer Execute Test")
          lead(:backend)

          agent(:backend) do
            model("gpt-4o-mini")
            description("Backend")
            system_prompt("Build APIs")
          end

          agent(:profiler) do
            model("gpt-4o-mini")
            description("Profiler")
            system_prompt("Analyze")
          end

          observer(:profiler) do
            on(:swarm_start) { |_e| nil } # Return nil to skip execution
          end
        end

        events = []

        stub_llm_request(mock_llm_response(content: "Done"))

        # Execute should setup observer manager
        swarm.execute("Test prompt") { |e| events << e }

        # Verify execution completed
        assert_predicate(events, :any?)
      end
    end
  end
end
