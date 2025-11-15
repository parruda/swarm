# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class McpServerDslTest < Minitest::Test
    def setup
      ENV["OPENAI_API_KEY"] = "test-key"
      RubyLLM.configure { |c| c.openai_api_key = "test-key" }
    end

    def test_mcp_server_stdio_configuration
      builder = Agent::Builder.new(:test_agent)
      builder.instance_eval do
        description("Test")
        model("gpt-4")
        mcp_server(
          :filesystem,
          type: :stdio,
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem"],
          env: { LOG_LEVEL: "debug" },
        )
      end

      definition = builder.to_definition
      servers = definition.mcp_servers

      assert_equal(1, servers.size)
      assert_equal(:filesystem, servers[0][:name])
      assert_equal(:stdio, servers[0][:type])
      assert_equal("npx", servers[0][:command])
      assert_equal(["-y", "@modelcontextprotocol/server-filesystem"], servers[0][:args])
      assert_equal({ LOG_LEVEL: "debug" }, servers[0][:env])
    end

    def test_mcp_server_sse_configuration
      builder = Agent::Builder.new(:test_agent)
      builder.instance_eval do
        description("Test")
        model("gpt-4")
        mcp_server(
          :web,
          type: :sse,
          url: "https://example.com/mcp",
          headers: { authorization: "Bearer token" },
          version: :http2,
        )
      end

      definition = builder.to_definition
      servers = definition.mcp_servers

      assert_equal(1, servers.size)
      assert_equal(:web, servers[0][:name])
      assert_equal(:sse, servers[0][:type])
      assert_equal("https://example.com/mcp", servers[0][:url])
      assert_equal({ authorization: "Bearer token" }, servers[0][:headers])
      assert_equal(:http2, servers[0][:version])
    end

    def test_mcp_server_http_configuration
      builder = Agent::Builder.new(:test_agent)
      builder.instance_eval do
        description("Test")
        model("gpt-4")
        mcp_server(
          :api,
          type: :http,
          url: "https://api.example.com/mcp",
          timeout: 60,
        )
      end

      definition = builder.to_definition
      servers = definition.mcp_servers

      assert_equal(1, servers.size)
      assert_equal(:api, servers[0][:name])
      assert_equal(:http, servers[0][:type])
      assert_equal("https://api.example.com/mcp", servers[0][:url])
      assert_equal(60, servers[0][:timeout])
    end

    def test_multiple_mcp_servers
      builder = Agent::Builder.new(:test_agent)
      builder.instance_eval do
        description("Test")
        model("gpt-4")
        mcp_server(:server1, type: :stdio, command: "cmd1")
        mcp_server(:server2, type: :sse, url: "https://example.com")
        mcp_server(:server3, type: :http, url: "https://api.example.com")
      end

      definition = builder.to_definition
      servers = definition.mcp_servers

      assert_equal(3, servers.size)
      assert_equal(:server1, servers[0][:name])
      assert_equal(:server2, servers[1][:name])
      assert_equal(:server3, servers[2][:name])
    end

    def test_mcp_server_passed_to_swarm
      # Create a minimal swarm without initializing agents (to avoid MCP connection attempts)
      swarm = Swarm.new(name: "Test")
      swarm.add_agent(create_agent(
        name: :test,
        description: "Test",
        model: "gpt-4",
        system_prompt: "Test",
        mcp_servers: [
          { name: :server1, type: :stdio, command: "cmd" },
        ],
      ))

      agent_def = swarm.agent_definition(:test)

      assert_equal(1, agent_def.mcp_servers.size)
      assert_equal(:server1, agent_def.mcp_servers[0][:name])
    end
  end
end
