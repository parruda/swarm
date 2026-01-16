# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class Swarm
    class McpConfiguratorTest < Minitest::Test
      # Mock emitter for capturing events
      class MockEmitter
        attr_reader :events

        def initialize
          @events = []
        end

        def emit(entry)
          @events << entry
        end
      end

      # Mock MCP client that returns mock tools
      class MockMcpClient
        attr_reader :tools

        def initialize(tools: [])
          @tools = tools
        end
      end

      # Mock tool for discovery mode testing
      class MockTool
        attr_reader :name

        def initialize(name)
          @name = name
        end
      end

      # Mock chat with tool registry for testing
      class MockToolRegistry
        attr_reader :registered_tools

        def initialize
          @registered_tools = []
        end

        def register(tool, source:, metadata:)
          @registered_tools << { tool: tool, source: source, metadata: metadata }
        end
      end

      class MockChat
        attr_reader :tool_registry

        def initialize
          @tool_registry = MockToolRegistry.new
        end
      end

      def setup
        @emitter = MockEmitter.new
        LogStream.emitter = @emitter

        @swarm = Swarm.new(name: "Test Swarm")
        @configurator = McpConfigurator.new(@swarm)
        @mock_chat = MockChat.new
      end

      def teardown
        LogStream.reset!
      end

      def test_register_mcp_servers_emits_start_and_complete_events_discovery_mode
        mock_tools = [MockTool.new("read"), MockTool.new("write")]
        mock_client = MockMcpClient.new(tools: mock_tools)

        # Stub the MCP client creation
        RubyLLM::MCP.stub(:client, mock_client) do
          server_configs = [{ name: :test_server, type: :stdio, command: "test-cmd" }]

          @configurator.register_mcp_servers(@mock_chat, server_configs, agent_name: :test_agent)
        end

        # Should have start and complete events
        assert_equal(2, @emitter.events.size)

        start_event = @emitter.events.find { |e| e[:type] == "mcp_server_init_start" }
        complete_event = @emitter.events.find { |e| e[:type] == "mcp_server_init_complete" }

        # Verify start event
        assert_equal(:test_agent, start_event[:agent])
        assert_equal(:test_server, start_event[:server_name])
        assert_equal(:stdio, start_event[:transport_type])
        assert_equal(:discovery, start_event[:mode])

        # Verify complete event
        assert_equal(:test_agent, complete_event[:agent])
        assert_equal(:test_server, complete_event[:server_name])
        assert_equal(:stdio, complete_event[:transport_type])
        assert_equal(:discovery, complete_event[:mode])
        assert_equal(2, complete_event[:tool_count])
        assert_equal(["read", "write"], complete_event[:tools])
      end

      def test_register_mcp_servers_emits_events_optimized_mode
        mock_client = MockMcpClient.new(tools: [])

        # Stub the MCP client creation
        RubyLLM::MCP.stub(:client, mock_client) do
          server_configs = [
            { name: :fast_server, type: :sse, url: "https://example.com", tools: [:search, :list] },
          ]

          @configurator.register_mcp_servers(@mock_chat, server_configs, agent_name: :backend)
        end

        # Should have start and complete events
        assert_equal(2, @emitter.events.size)

        start_event = @emitter.events.find { |e| e[:type] == "mcp_server_init_start" }
        complete_event = @emitter.events.find { |e| e[:type] == "mcp_server_init_complete" }

        # Verify start event uses optimized mode
        assert_equal(:backend, start_event[:agent])
        assert_equal(:fast_server, start_event[:server_name])
        assert_equal(:sse, start_event[:transport_type])
        assert_equal(:optimized, start_event[:mode])

        # Verify complete event
        assert_equal(:optimized, complete_event[:mode])
        assert_equal(2, complete_event[:tool_count])
        assert_equal(["search", "list"], complete_event[:tools])
      end

      def test_register_mcp_servers_emits_events_for_multiple_servers
        mock_tools = [MockTool.new("tool1")]
        mock_client = MockMcpClient.new(tools: mock_tools)

        RubyLLM::MCP.stub(:client, mock_client) do
          server_configs = [
            { name: :server1, type: :stdio, command: "cmd1" },
            { name: :server2, type: :sse, url: "https://example.com", tools: [:custom_tool] },
          ]

          @configurator.register_mcp_servers(@mock_chat, server_configs, agent_name: :multi_agent)
        end

        # Should have 2 start and 2 complete events (4 total)
        assert_equal(4, @emitter.events.size)

        start_events = @emitter.events.select { |e| e[:type] == "mcp_server_init_start" }
        complete_events = @emitter.events.select { |e| e[:type] == "mcp_server_init_complete" }

        assert_equal(2, start_events.size)
        assert_equal(2, complete_events.size)

        # First server: discovery mode
        assert_equal(:server1, start_events[0][:server_name])
        assert_equal(:discovery, start_events[0][:mode])

        # Second server: optimized mode
        assert_equal(:server2, start_events[1][:server_name])
        assert_equal(:optimized, start_events[1][:mode])
      end

      def test_register_mcp_servers_events_include_timestamp
        mock_client = MockMcpClient.new(tools: [MockTool.new("test")])

        RubyLLM::MCP.stub(:client, mock_client) do
          server_configs = [{ name: :test_server, type: :stdio, command: "cmd" }]
          @configurator.register_mcp_servers(@mock_chat, server_configs, agent_name: :test_agent)
        end

        @emitter.events.each do |event|
          assert(event.key?(:timestamp), "Event should include timestamp")
          assert_match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, event[:timestamp])
        end
      end

      def test_register_mcp_servers_no_events_when_no_emitter
        LogStream.reset!
        local_emitter = MockEmitter.new

        mock_client = MockMcpClient.new(tools: [MockTool.new("test")])

        RubyLLM::MCP.stub(:client, mock_client) do
          server_configs = [{ name: :test_server, type: :stdio, command: "cmd" }]
          @configurator.register_mcp_servers(@mock_chat, server_configs, agent_name: :test_agent)
        end

        # No events captured since emitter was reset
        assert_equal(0, local_emitter.events.size)
      end

      def test_register_mcp_servers_does_nothing_for_empty_config
        @configurator.register_mcp_servers(@mock_chat, [], agent_name: :test_agent)
        @configurator.register_mcp_servers(@mock_chat, nil, agent_name: :test_agent)

        assert_equal(0, @emitter.events.size)
      end

      def test_build_transport_config_stdio
        config = {
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-test"],
          env: { "DEBUG" => "true" },
        }

        result = @configurator.build_transport_config(:stdio, config)

        assert_equal("npx", result[:command])
        assert_equal(["-y", "@modelcontextprotocol/server-test"], result[:args])
        assert_equal({ "DEBUG" => "true" }, result[:env])
      end

      def test_build_transport_config_sse
        config = {
          url: "https://example.com/mcp",
          headers: { "Authorization" => "Bearer token" },
          version: :http2,
        }

        result = @configurator.build_transport_config(:sse, config)

        assert_equal("https://example.com/mcp", result[:url])
        assert_equal({ "Authorization" => "Bearer token" }, result[:headers])
        assert_equal(:http2, result[:version])
      end

      def test_build_transport_config_streamable
        config = {
          url: "https://api.example.com/mcp",
          headers: { "X-Api-Key" => "secret" },
          version: :http1,
          rate_limit: 10,
        }

        result = @configurator.build_transport_config(:streamable, config)

        assert_equal("https://api.example.com/mcp", result[:url])
        assert_equal({ "X-Api-Key" => "secret" }, result[:headers])
        assert_equal(:http1, result[:version])
        assert_equal(10, result[:rate_limit])
      end

      def test_build_transport_config_streamable_without_rate_limit
        config = {
          url: "https://api.example.com/mcp",
        }

        result = @configurator.build_transport_config(:streamable, config)

        refute(result.key?(:rate_limit), "Should not include rate_limit when not specified")
      end

      def test_build_transport_config_raises_for_unknown_type
        assert_raises(ArgumentError) do
          @configurator.build_transport_config(:unknown, {})
        end
      end
    end
  end
end
