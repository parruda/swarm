# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Tools
    class McpToolStubTest < Minitest::Test
      # Mock client for testing
      class MockClient
        attr_reader :tool_info_called, :call_tool_called

        def initialize(tools_data)
          @tools_data = tools_data
          @tool_info_called = false
          @call_tool_called = false
        end

        def tool_info(name)
          @tool_info_called = true
          @tools_data.find { |t| t["name"] == name }
        end

        def call_tool(name:, arguments:)
          @call_tool_called = true
          "Result for #{name} with #{arguments}"
        end
      end

      # Mock result
      class MockResult
        def initialize(success:, content:)
          @success = success
          @content = content
        end

        def error?
          !@success
        end

        def execution_error?
          false
        end

        def value
          { "content" => @content }
        end

        def to_error
          "Error"
        end
      end

      def test_creates_stub_with_minimal_info
        client = MockClient.new([])
        stub = McpToolStub.new(client: client, name: "test_tool")

        assert_equal("test_tool", stub.name)
        assert_equal("MCP tool: test_tool", stub.description)
      end

      def test_creates_stub_with_description
        client = MockClient.new([])
        stub = McpToolStub.new(
          client: client,
          name: "search",
          description: "Search the codebase",
        )

        assert_equal("search", stub.name)
        assert_equal("Search the codebase", stub.description)
      end

      def test_creates_stub_with_schema
        client = MockClient.new([])
        schema = { type: "object", properties: { query: { type: "string" } } }
        stub = McpToolStub.new(
          client: client,
          name: "search",
          schema: schema,
        )

        assert_equal(schema, stub.params_schema)
      end

      def test_schema_not_loaded_on_initialization
        client = MockClient.new([])
        _stub = McpToolStub.new(client: client, name: "test_tool")

        refute(client.tool_info_called, "Should not call tool_info on initialization")
      end

      def test_schema_loaded_lazily_on_first_access
        tools_data = [
          { "name" => "test_tool", "description" => "Test description", "inputSchema" => { "type" => "object" } },
        ]
        client = MockClient.new(tools_data)
        stub = McpToolStub.new(client: client, name: "test_tool")

        refute(client.tool_info_called, "Should not call tool_info before schema access")

        schema = stub.params_schema

        assert(client.tool_info_called, "Should call tool_info on first schema access")
        assert_equal({ "type" => "object" }, schema)
      end

      def test_schema_cached_after_first_load
        # Use a client that tracks call count instead of boolean flag
        tools_data = [
          { "name" => "test_tool", "inputSchema" => { "type" => "object" } },
        ]

        client = Object.new
        def client.tool_info_data=(data)
          @tools_data = data
          @call_count = 0
        end

        def client.tool_info(name)
          @call_count ||= 0
          @call_count += 1
          @tools_data.find { |t| t["name"] == name }
        end

        def client.call_count
          @call_count || 0
        end
        client.tool_info_data = tools_data

        stub = McpToolStub.new(client: client, name: "test_tool")

        # First access
        stub.params_schema

        assert_equal(1, client.call_count, "Should call tool_info once")

        # Second access
        stub.params_schema

        assert_equal(1, client.call_count, "Should NOT call tool_info again (cached)")
      end

      def test_updates_description_from_server
        tools_data = [
          { "name" => "test_tool", "description" => "Server description", "inputSchema" => { "type" => "object" } },
        ]
        client = MockClient.new(tools_data)
        stub = McpToolStub.new(client: client, name: "test_tool")

        assert_equal("MCP tool: test_tool", stub.description)

        # Access schema triggers description update
        stub.params_schema

        assert_equal("Server description", stub.description)
      end

      def test_handles_missing_tool_gracefully
        tools_data = [
          { "name" => "other_tool", "inputSchema" => {} },
        ]
        client = MockClient.new(tools_data)
        stub = McpToolStub.new(client: client, name: "missing_tool")

        # Access schema when tool doesn't exist
        schema = stub.params_schema

        # Should return nil gracefully (not raise)
        assert_nil(schema, "Schema should be nil for missing tool")

        # Schema should be marked as loaded even though tool wasn't found
        assert(client.tool_info_called, "Should have attempted to fetch schema")
      end

      def test_execute_calls_client
        client = MockClient.new([])
        stub = McpToolStub.new(client: client, name: "test_tool")

        result = stub.execute(query: "test")

        assert(client.call_tool_called, "Should call call_tool on client")
        assert_match(/Result for test_tool/, result)
      end

      def test_is_removable
        client = MockClient.new([])
        stub = McpToolStub.new(client: client, name: "test_tool")

        assert_predicate(stub, :removable?, "MCP tools should be removable by default")
      end

      def test_inherits_from_base
        client = MockClient.new([])
        stub = McpToolStub.new(client: client, name: "test_tool")

        assert_kind_of(SwarmSDK::Tools::Base, stub)
      end

      def test_stores_server_name
        client = MockClient.new([])
        stub = McpToolStub.new(
          client: client,
          name: "test_tool",
          server_name: "my_mcp_server",
        )

        assert_equal("my_mcp_server", stub.server_name)
      end

      def test_server_name_defaults_to_unknown
        client = MockClient.new([])
        stub = McpToolStub.new(client: client, name: "test_tool")

        assert_equal("unknown", stub.server_name)
      end

      # Mock client that raises MCP errors
      class ErrorRaisingClient
        attr_accessor :error_to_raise

        def tool_info(_name)
          raise @error_to_raise if @error_to_raise

          nil
        end

        def call_tool(name:, arguments:)
          raise @error_to_raise if @error_to_raise

          "Result for #{name}"
        end
      end

      def test_execute_wraps_timeout_error_with_context
        client = ErrorRaisingClient.new
        client.error_to_raise = RubyLLM::MCP::Errors::TimeoutError.new(
          message: "Request timed out after 30 seconds",
          request_id: "req_123",
        )

        stub = McpToolStub.new(
          client: client,
          name: "search_code",
          server_name: "codebase_server",
        )

        error = assert_raises(SwarmSDK::MCPTimeoutError) do
          stub.execute(query: "test")
        end

        assert_includes(error.message, "MCP request timed out")
        assert_includes(error.message, "[server: codebase_server]")
        assert_includes(error.message, "[tool: search_code]")
        assert_includes(error.message, "[request_id: req_123]")
        assert_includes(error.message, "Request timed out after 30 seconds")
      end

      def test_execute_wraps_transport_error_with_context
        client = ErrorRaisingClient.new
        client.error_to_raise = RubyLLM::MCP::Errors::TransportError.new(
          message: "Connection refused",
          code: 502,
        )

        stub = McpToolStub.new(
          client: client,
          name: "search_code",
          server_name: "codebase_server",
        )

        error = assert_raises(SwarmSDK::MCPTransportError) do
          stub.execute(query: "test")
        end

        assert_includes(error.message, "MCP transport error")
        assert_includes(error.message, "[server: codebase_server]")
        assert_includes(error.message, "[tool: search_code]")
        assert_includes(error.message, "[code: 502]")
        assert_includes(error.message, "Connection refused")
      end

      def test_execute_wraps_base_error_with_context
        client = ErrorRaisingClient.new
        client.error_to_raise = RubyLLM::MCP::Errors::BaseError.new(
          message: "Unknown MCP error",
        )

        stub = McpToolStub.new(
          client: client,
          name: "search_code",
          server_name: "codebase_server",
        )

        error = assert_raises(SwarmSDK::MCPError) do
          stub.execute(query: "test")
        end

        assert_includes(error.message, "MCP error")
        assert_includes(error.message, "[server: codebase_server]")
        assert_includes(error.message, "[tool: search_code]")
        assert_includes(error.message, "Unknown MCP error")
      end

      def test_schema_loading_wraps_timeout_error_with_context
        client = ErrorRaisingClient.new
        client.error_to_raise = RubyLLM::MCP::Errors::TimeoutError.new(
          message: "Request timed out after 30 seconds",
          request_id: "req_456",
        )

        stub = McpToolStub.new(
          client: client,
          name: "search_code",
          server_name: "codebase_server",
        )

        error = assert_raises(SwarmSDK::MCPTimeoutError) do
          stub.params_schema
        end

        assert_includes(error.message, "MCP schema fetch timed out")
        assert_includes(error.message, "[server: codebase_server]")
        assert_includes(error.message, "[tool: search_code]")
        assert_includes(error.message, "[request_id: req_456]")
      end

      def test_schema_loading_wraps_transport_error_with_context
        client = ErrorRaisingClient.new
        client.error_to_raise = RubyLLM::MCP::Errors::TransportError.new(
          message: "SSL handshake failed",
          code: 0,
        )

        stub = McpToolStub.new(
          client: client,
          name: "search_code",
          server_name: "codebase_server",
        )

        error = assert_raises(SwarmSDK::MCPTransportError) do
          stub.params_schema
        end

        assert_includes(error.message, "MCP transport error during schema fetch")
        assert_includes(error.message, "[server: codebase_server]")
        assert_includes(error.message, "[code: 0]")
      end

      def test_schema_loading_wraps_base_error_with_context
        client = ErrorRaisingClient.new
        client.error_to_raise = RubyLLM::MCP::Errors::BaseError.new(
          message: "Protocol error",
        )

        stub = McpToolStub.new(
          client: client,
          name: "search_code",
          server_name: "codebase_server",
        )

        error = assert_raises(SwarmSDK::MCPError) do
          stub.params_schema
        end

        assert_includes(error.message, "MCP error during schema fetch")
        assert_includes(error.message, "[server: codebase_server]")
        assert_includes(error.message, "Protocol error")
      end
    end
  end
end
