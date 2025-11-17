# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Observer
    class ConfigTest < Minitest::Test
      def test_initializes_with_agent_name
        config = Config.new(:profiler)

        assert_equal(:profiler, config.agent_name)
        assert_empty(config.event_handlers)
      end

      def test_has_default_options
        config = Config.new(:monitor)

        assert_nil(config.options[:max_concurrent])
        assert_equal(60, config.options[:timeout])
        assert(config.options[:fire_and_forget])
      end

      def test_add_handler_stores_block
        config = Config.new(:profiler)
        handler_block = ->(event) { "Analyze: #{event[:prompt]}" }

        config.add_handler(:swarm_start, &handler_block)

        assert_equal(handler_block, config.event_handlers[:swarm_start])
      end

      def test_add_multiple_handlers
        config = Config.new(:monitor)

        config.add_handler(:tool_call) { |event| "Check tool: #{event[:tool_name]}" }
        config.add_handler(:tool_result) { |event| "Result: #{event[:result]}" }

        assert_equal(2, config.event_handlers.size)
        assert(config.event_handlers.key?(:tool_call))
        assert(config.event_handlers.key?(:tool_result))
      end

      def test_handler_block_can_return_prompt
        config = Config.new(:profiler)

        config.add_handler(:swarm_start) do |event|
          "Analyze this: #{event[:prompt]}"
        end

        prompt = config.event_handlers[:swarm_start].call(prompt: "Hello")

        assert_equal("Analyze this: Hello", prompt)
      end

      def test_handler_block_can_return_nil
        config = Config.new(:monitor)

        config.add_handler(:tool_call) do |event|
          next unless event[:tool_name] == "Bash"

          "Check: #{event[:arguments][:command]}"
        end

        # Should return nil for non-Bash tool
        result = config.event_handlers[:tool_call].call(tool_name: "Read")

        assert_nil(result)

        # Should return prompt for Bash tool
        result = config.event_handlers[:tool_call].call(tool_name: "Bash", arguments: { command: "ls" })

        assert_equal("Check: ls", result)
      end

      def test_options_can_be_modified
        config = Config.new(:profiler)

        config.options[:timeout] = 120
        config.options[:max_concurrent] = 2
        config.options[:fire_and_forget] = false

        assert_equal(120, config.options[:timeout])
        assert_equal(2, config.options[:max_concurrent])
        refute(config.options[:fire_and_forget])
      end

      def test_options_can_be_merged
        config = Config.new(:profiler)

        new_options = { timeout: 180, max_concurrent: 5 }
        config.options.merge!(new_options)

        assert_equal(180, config.options[:timeout])
        assert_equal(5, config.options[:max_concurrent])
        # Original option preserved
        assert(config.options[:fire_and_forget])
      end
    end
  end
end
