# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Observer
    class BuilderTest < Minitest::Test
      def test_on_adds_handler_to_config
        config = Config.new(:profiler)
        builder = Builder.new(:profiler, config)

        builder.on(:swarm_start) { |event| "Analyze: #{event[:prompt]}" }

        assert(config.event_handlers.key?(:swarm_start))
      end

      def test_on_multiple_event_types
        config = Config.new(:monitor)
        builder = Builder.new(:monitor, config)

        builder.on(:tool_call) { |_e| "tool" }
        builder.on(:tool_result) { |_e| "result" }
        builder.on(:agent_stop) { |_e| "stop" }

        assert_equal(3, config.event_handlers.size)
      end

      def test_max_concurrent_sets_option
        config = Config.new(:profiler)
        builder = Builder.new(:profiler, config)

        builder.max_concurrent(3)

        assert_equal(3, config.options[:max_concurrent])
      end

      def test_timeout_sets_option
        config = Config.new(:profiler)
        builder = Builder.new(:profiler, config)

        builder.timeout(120)

        assert_equal(120, config.options[:timeout])
      end

      def test_wait_for_completion_sets_fire_and_forget_to_false
        config = Config.new(:profiler)
        builder = Builder.new(:profiler, config)

        builder.wait_for_completion!

        refute(config.options[:fire_and_forget])
      end

      def test_instance_eval_usage
        config = Config.new(:profiler)
        builder = Builder.new(:profiler, config)

        builder.instance_eval do
          on(:swarm_start) { |event| "Start: #{event[:prompt]}" }
          timeout(180)
          max_concurrent(5)
        end

        assert(config.event_handlers.key?(:swarm_start))
        assert_equal(180, config.options[:timeout])
        assert_equal(5, config.options[:max_concurrent])
      end

      def test_handler_block_receives_event
        config = Config.new(:profiler)
        builder = Builder.new(:profiler, config)

        builder.on(:tool_call) do |event|
          case event[:tool_name]
          when "Bash"
            "Check: #{event[:arguments][:command]}"
          when "Write"
            "Verify: #{event[:arguments][:content]}"
          end
        end

        handler = config.event_handlers[:tool_call]

        bash_result = handler.call(tool_name: "Bash", arguments: { command: "ls" })

        assert_equal("Check: ls", bash_result)

        write_result = handler.call(tool_name: "Write", arguments: { content: "data" })

        assert_equal("Verify: data", write_result)

        read_result = handler.call(tool_name: "Read", arguments: {})

        assert_nil(read_result)
      end

      def test_chained_configuration
        config = Config.new(:monitor)
        builder = Builder.new(:monitor, config)

        builder.instance_eval do
          on(:tool_call) { |_e| "tool" }
          on(:tool_result) { |_e| "result" }
          timeout(240)
          max_concurrent(1)
          wait_for_completion!
        end

        assert_equal(2, config.event_handlers.size)
        assert_equal(240, config.options[:timeout])
        assert_equal(1, config.options[:max_concurrent])
        refute(config.options[:fire_and_forget])
      end
    end
  end
end
