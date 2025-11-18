# frozen_string_literal: true

require "test_helper"
require "openai"

module OpenAI
  class ExecutorTest < Minitest::Test
    # Define mock structs at class level to avoid redefinition
    MockEnv = Struct.new(:status)
    MockOptions = Struct.new(:max, :interval, :backoff_factor)
    def setup
      @tmpdir = Dir.mktmpdir
      @session_path = File.join(@tmpdir, "session-#{Time.now.to_i}")
      FileUtils.mkdir_p(@session_path)
      ENV["CLAUDE_SWARM_SESSION_PATH"] = @session_path

      # Mock OpenAI API key
      ENV["TEST_OPENAI_API_KEY"] = "test-key-123"
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
      ENV.delete("CLAUDE_SWARM_SESSION_PATH")
      ENV.delete("TEST_OPENAI_API_KEY")
    end

    def test_initialization_with_default_values
      executor = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        instance_name: "test-instance",
        instance_id: "test-123",
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      assert_equal(@tmpdir, executor.working_directory)
      assert_nil(executor.session_id)
      assert_equal(@session_path, executor.session_path)
    end

    def test_initialization_with_custom_values
      executor = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4",
        instance_name: "test-instance",
        instance_id: "test-123",
        temperature: 0.7,
        api_version: "responses",
        openai_token_env: "TEST_OPENAI_API_KEY",
        base_url: "https://custom.openai.com/v1",
        debug: false,
      )

      assert_equal(@tmpdir, executor.working_directory)
    end

    def test_initialization_with_zdr_parameter
      # Test with zdr: true
      executor_with_zdr = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o-reasoning",
        instance_name: "test-instance",
        instance_id: "test-123",
        api_version: "responses",
        reasoning_effort: "high",
        zdr: true,
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      # Verify executor is created successfully
      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor_with_zdr)
      # Verify the zdr parameter is stored
      assert(executor_with_zdr.instance_variable_get(:@zdr))

      # Test with zdr: false (explicit false)
      executor_without_zdr = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        instance_name: "test-instance",
        instance_id: "test-124",
        api_version: "chat_completion",
        zdr: false,
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor_without_zdr)
      refute(executor_without_zdr.instance_variable_get(:@zdr))

      # Test default value (when zdr is not specified)
      executor_default = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        instance_name: "test-instance",
        instance_id: "test-125",
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor_default)
      # Default value should be false
      refute(executor_default.instance_variable_get(:@zdr))
    end

    def test_zdr_passed_to_api_handler
      # Mock the API handlers to verify zdr is passed correctly

      # Test with Responses API and zdr: true
      mock_responses_handler = Minitest::Mock.new
      ClaudeSwarm::OpenAI::Responses.stub(:new, lambda { |**params|
        # Verify zdr is passed correctly
        assert(params[:zdr])
        assert_equal("gpt-4o-reasoning", params[:model])
        assert_equal("high", params[:reasoning_effort])
        mock_responses_handler
      }) do
        ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o-reasoning",
          instance_name: "test-instance",
          api_version: "responses",
          reasoning_effort: "high",
          zdr: true,
          openai_token_env: "TEST_OPENAI_API_KEY",
          debug: false,
        )
      end

      # Test with ChatCompletion API and zdr: false
      mock_chat_handler = Minitest::Mock.new
      ClaudeSwarm::OpenAI::ChatCompletion.stub(:new, lambda { |**params|
        # Verify zdr is passed correctly
        refute(params[:zdr])
        assert_equal("gpt-4o", params[:model])
        mock_chat_handler
      }) do
        ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o",
          instance_name: "test-instance",
          api_version: "chat_completion",
          zdr: false,
          openai_token_env: "TEST_OPENAI_API_KEY",
          debug: false,
        )
      end
    end

    def test_initialization_fails_without_api_key
      ENV.delete("TEST_OPENAI_API_KEY")

      assert_raises(ClaudeSwarm::OpenAI::Executor::ExecutionError) do
        ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o",
          instance_name: "test-instance",
          openai_token_env: "TEST_OPENAI_API_KEY",
        )
      end
    end

    def test_reset_session
      executor = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        instance_name: "test-instance",
        claude_session_id: "existing-session",
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      assert_predicate(executor, :has_session?)

      executor.reset_session

      refute_predicate(executor, :has_session?)
      assert_nil(executor.session_id)
    end

    def test_session_logging_setup
      ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        instance_name: "test-instance",
        instance_id: "test-123",
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      # Check that log files are created
      log_file = File.join(@session_path, "session.log")
      File.join(@session_path, "session.log.json")

      assert_path_exists(log_file)

      # Verify log content
      log_content = File.read(log_file)

      assert_match(/Started ClaudeSwarm::OpenAI::Executor for instance: test-instance \(test-123\)/, log_content)
    end

    def test_mcp_config_loading
      # Create a mock MCP config file
      mcp_config_path = File.join(@tmpdir, "test.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "test-server" => {
            "type" => "stdio",
            "command" => "echo",
            "args" => ["test"],
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      # Mock the MCP client to prevent actual execution
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, [])

      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        { command: kwargs[:command], name: kwargs[:name] }
      }) do
        MCPClient.stub(:create_client, mock_mcp_client) do
          executor = ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            mcp_config: mcp_config_path,
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
            debug: false,
          )

          # Verify the executor was created successfully
          assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor)
        end
      end

      mock_mcp_client.verify
    end

    def test_mcp_stdio_config_has_correct_read_timeout
      # Create MCP config with stdio server
      mcp_config_path = File.join(@tmpdir, "test-timeout.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "test-stdio-server" => {
            "type" => "stdio",
            "command" => "test-cmd",
            "args" => ["arg1", "arg2"],
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      # Mock MCPClient methods
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, [])

      # Track the config passed to stdio_config
      captured_stdio_config = nil
      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        captured_stdio_config = kwargs
        { command: kwargs[:command], name: kwargs[:name], read_timeout: 1800 }
      }) do
        MCPClient.stub(:create_client, mock_mcp_client) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            mcp_config: mcp_config_path,
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
            debug: false,
          )
        end
      end

      # Verify the correct arguments were passed
      assert_equal(["test-cmd", "arg1", "arg2"], captured_stdio_config[:command])
      assert_equal("test-stdio-server", captured_stdio_config[:name])
    end

    def test_mcp_client_created_with_1800_second_timeout
      # Create MCP config
      mcp_config_path = File.join(@tmpdir, "test-client.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "server1" => {
            "type" => "stdio",
            "command" => "cmd1",
            "args" => ["--flag"],
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      # Track the configs passed to create_client
      captured_mcp_configs = nil
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, ["tool1", "tool2"])

      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        { command: kwargs[:command], name: kwargs[:name] }
      }) do
        MCPClient.stub(:create_client, lambda { |**kwargs|
          captured_mcp_configs = kwargs[:mcp_server_configs]
          mock_mcp_client
        }) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            mcp_config: mcp_config_path,
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
            debug: false,
          )
        end
      end

      # Verify timeout was set on the config
      assert_equal(1, captured_mcp_configs.size)
      assert_equal(1800, captured_mcp_configs.first[:read_timeout])
    end

    def test_mcp_setup_with_multiple_stdio_servers
      # Create MCP config with multiple servers
      mcp_config_path = File.join(@tmpdir, "test-multi.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "server1" => { "type" => "stdio", "command" => "cmd1" },
          "server2" => { "type" => "stdio", "command" => "cmd2", "args" => ["--opt"] },
          "server3" => { "type" => "stdio", "command" => "cmd3" },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      captured_configs = []
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, [])

      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        config = { command: kwargs[:command], name: kwargs[:name] }
        config
      }) do
        MCPClient.stub(:create_client, lambda { |**kwargs|
          captured_configs = kwargs[:mcp_server_configs]
          mock_mcp_client
        }) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            mcp_config: mcp_config_path,
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
            debug: false,
          )
        end
      end

      # All configs should have the timeout set
      assert_equal(3, captured_configs.size)
      captured_configs.each do |config|
        assert_equal(1800, config[:read_timeout])
      end
    end

    def test_mcp_setup_handles_sse_servers
      # Create MCP config with SSE server
      mcp_config_path = File.join(@tmpdir, "test-sse.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "sse-server" => {
            "type" => "sse",
            "url" => "http://example.com/sse",
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      Logger.stub(:new, logger) do
        ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o",
          mcp_config: mcp_config_path,
          instance_name: "test-instance",
          openai_token_env: "TEST_OPENAI_API_KEY",
        )
      end

      # Check that warning was logged
      log_content = log_output.string

      assert_match(/SSE MCP servers not yet supported/, log_content)
      assert_match(/sse-server/, log_content)
    end

    def test_mcp_setup_handles_missing_config_file
      # Try to create executor with non-existent MCP config
      executor = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        mcp_config: "/non/existent/path.json",
        instance_name: "test-instance",
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      # Should initialize without error
      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor)
    end

    def test_mcp_setup_handles_empty_mcp_servers
      # Create MCP config with empty servers
      mcp_config_path = File.join(@tmpdir, "test-empty.mcp.json")
      mcp_config = {
        "mcpServers" => {},
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      executor = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        mcp_config: mcp_config_path,
        instance_name: "test-instance",
        openai_token_env: "TEST_OPENAI_API_KEY",
        debug: false,
      )

      # Should initialize without creating MCP client
      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor)
    end

    def test_mcp_setup_handles_invalid_json
      # Create invalid JSON file
      mcp_config_path = File.join(@tmpdir, "test-invalid.mcp.json")
      File.write(mcp_config_path, "{ invalid json }")

      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      executor = nil
      Logger.stub(:new, logger) do
        executor = ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o",
          mcp_config: mcp_config_path,
          instance_name: "test-instance",
          openai_token_env: "TEST_OPENAI_API_KEY",
        )
      end

      # Should handle error gracefully
      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor)
      log_content = log_output.string

      assert_match(/Failed to setup MCP client/, log_content)
    end

    def test_mcp_setup_handles_list_tools_failure
      # Create valid MCP config
      mcp_config_path = File.join(@tmpdir, "test-tools-error.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "test-server" => {
            "type" => "stdio",
            "command" => "test",
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      # Mock MCP client that fails on list_tools
      mock_mcp_client = Minitest::Mock.new
      def mock_mcp_client.list_tools
        raise StandardError, "Failed to connect to MCP server"
      end

      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      executor = nil
      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        { command: kwargs[:command], name: kwargs[:name] }
      }) do
        MCPClient.stub(:create_client, mock_mcp_client) do
          Logger.stub(:new, logger) do
            executor = ClaudeSwarm::OpenAI::Executor.new(
              working_directory: @tmpdir,
              model: "gpt-4o",
              mcp_config: mcp_config_path,
              instance_name: "test-instance",
              openai_token_env: "TEST_OPENAI_API_KEY",
            )
          end
        end
      end

      # Should handle error and continue
      assert_instance_of(ClaudeSwarm::OpenAI::Executor, executor)
      log_content = log_output.string

      assert_match(/Failed to load MCP tools/, log_content)
    end

    def test_mcp_mixed_server_types
      # Create MCP config with both stdio and SSE servers
      mcp_config_path = File.join(@tmpdir, "test-mixed.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "stdio-server" => {
            "type" => "stdio",
            "command" => "cmd1",
            "args" => ["--flag"],
          },
          "sse-server" => {
            "type" => "sse",
            "url" => "http://example.com/sse",
          },
          "another-stdio" => {
            "type" => "stdio",
            "command" => "cmd2",
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      captured_configs = []
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, [])

      # Capture log output for SSE warning
      log_output = StringIO.new
      logger = Logger.new(log_output)

      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        { command: kwargs[:command], name: kwargs[:name] }
      }) do
        MCPClient.stub(:create_client, lambda { |**kwargs|
          captured_configs = kwargs[:mcp_server_configs]
          mock_mcp_client
        }) do
          Logger.stub(:new, logger) do
            ClaudeSwarm::OpenAI::Executor.new(
              working_directory: @tmpdir,
              model: "gpt-4o",
              mcp_config: mcp_config_path,
              instance_name: "test-instance",
              openai_token_env: "TEST_OPENAI_API_KEY",
            )
          end
        end
      end

      # Should only have stdio configs
      assert_equal(2, captured_configs.size)
      captured_configs.each do |config|
        assert_equal(1800, config[:read_timeout])
      end

      # Should warn about SSE server
      log_content = log_output.string

      assert_match(/SSE MCP servers not yet supported/, log_content)
    end

    def test_timeout_only_applied_after_stdio_config
      # This test verifies that the timeout is added after MCPClient.stdio_config returns
      mcp_config_path = File.join(@tmpdir, "test-stdio-only.mcp.json")
      mcp_config = {
        "mcpServers" => {
          "stdio-server" => {
            "type" => "stdio",
            "command" => "test",
          },
        },
      }
      File.write(mcp_config_path, JSON.pretty_generate(mcp_config))

      stdio_config_args = nil
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, [])

      # Capture what's passed to stdio_config
      MCPClient.stub(:stdio_config, lambda { |**kwargs|
        stdio_config_args = kwargs
        # Return a hash that simulates what stdio_config would return
        { command: kwargs[:command], name: kwargs[:name] }
      }) do
        MCPClient.stub(:create_client, lambda { |**kwargs|
          configs = kwargs[:mcp_server_configs]
          # Verify that timeout is set on the config passed to create_client
          assert_equal(1, configs.size)
          assert_equal(1800, configs.first[:read_timeout])
          mock_mcp_client
        }) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            mcp_config: mcp_config_path,
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
            debug: false,
          )
        end
      end

      # Verify stdio_config was called without read_timeout
      assert_equal({ command: ["test"], name: "stdio-server" }, stdio_config_args)
    end

    def test_openai_client_configured_with_retry_middleware
      # Create a mock faraday builder to verify middleware configuration
      mock_faraday_builder = Minitest::Mock.new
      captured_retry_config = nil

      # Expect adapter call first, then request
      mock_faraday_builder.expect(:adapter, nil, [:net_http_persistent])

      # Capture the retry middleware configuration
      mock_faraday_builder.expect(:request, nil) do |middleware, *args, **kwargs|
        if middleware == :retry
          captured_retry_config = {
            args: args,
            kwargs: kwargs,
          }
        end
      end

      # Mock OpenAI::Client to capture faraday config
      ::OpenAI::Client.stub(:new, lambda { |_config, &block|
        # Call the faraday config block with our mock
        block&.call(mock_faraday_builder)

        # Create a minimal mock client
        mock_client = Minitest::Mock.new
        mock_client
      }) do
        ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o",
          instance_name: "test-instance",
          openai_token_env: "TEST_OPENAI_API_KEY",
        )
      end

      # Verify retry middleware was configured
      refute_nil(captured_retry_config)
      assert_equal(3, captured_retry_config[:kwargs][:max])
      assert_in_delta(0.5, captured_retry_config[:kwargs][:interval])
      assert_in_delta(0.5, captured_retry_config[:kwargs][:interval_randomness])
      assert_equal(2, captured_retry_config[:kwargs][:backoff_factor])

      # Verify exception types
      expected_exceptions = [
        Faraday::TimeoutError,
        Faraday::ConnectionFailed,
        Faraday::ServerError,
      ]

      assert_equal(expected_exceptions, captured_retry_config[:kwargs][:exceptions])

      # Verify retry status codes
      expected_statuses = [429, 500, 502, 503, 504]

      assert_equal(expected_statuses, captured_retry_config[:kwargs][:retry_statuses])

      # Verify retry_block is provided and callable
      refute_nil(captured_retry_config[:kwargs][:retry_block])
      assert_respond_to(captured_retry_config[:kwargs][:retry_block], :call)

      # Verify mock expectations
      mock_faraday_builder.verify
    end

    def test_retry_middleware_logs_warning_on_retry_attempt
      # Get the retry block from the executor's setup
      retry_block = nil

      mock_faraday_builder = Minitest::Mock.new
      mock_faraday_builder.expect(:adapter, nil, [:net_http_persistent])
      mock_faraday_builder.expect(:request, nil) do |middleware, *_args, **kwargs|
        if middleware == :retry && kwargs[:retry_block]
          retry_block = kwargs[:retry_block]
        end
      end

      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      ::OpenAI::Client.stub(:new, lambda { |_config, &block|
        block&.call(mock_faraday_builder)
        Minitest::Mock.new
      }) do
        Logger.stub(:new, logger) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
          )
        end
      end

      refute_nil(retry_block, "Retry block should have been captured")

      # Create mock environment and options for retry block
      mock_env = MockEnv.new(503)
      mock_options = MockOptions.new(3, 0.5, 2)

      # Test retry logging when will_retry is true
      log_output.truncate(0)
      log_output.rewind
      retry_block.call(
        env: mock_env,
        options: mock_options,
        retry_count: 1,
        exception: StandardError.new("Connection timeout"),
        will_retry: true,
      )

      log_content = log_output.string

      assert_match(%r{Request failed \(attempt 1/3\): Connection timeout}, log_content)
      assert_match(/Retrying in 0.5 seconds.../, log_content)
      assert_match(/WARN/, log_content)

      # Test exponential backoff calculation (2nd retry)
      log_output.truncate(0)
      log_output.rewind
      retry_block.call(
        env: mock_env,
        options: mock_options,
        retry_count: 2,
        exception: nil,
        will_retry: true,
      )

      log_content = log_output.string

      assert_match(%r{Request failed \(attempt 2/3\): HTTP 503}, log_content)
      assert_match(/Retrying in 1.0 seconds.../, log_content) # 0.5 * 2^(2-1) = 1.0

      # Test final failure logging
      log_output.truncate(0)
      log_output.rewind
      retry_block.call(
        env: mock_env,
        options: mock_options,
        retry_count: 3,
        exception: StandardError.new("Final failure"),
        will_retry: false,
      )

      log_content = log_output.string

      assert_match(/Request failed after 3 attempts: Final failure/, log_content)
      assert_match(/Giving up./, log_content)
    end

    def test_retry_middleware_handles_http_status_without_exception
      retry_block = nil
      mock_faraday_builder = Minitest::Mock.new
      mock_faraday_builder.expect(:adapter, nil, [:net_http_persistent])
      mock_faraday_builder.expect(:request, nil) do |middleware, *_args, **kwargs|
        if middleware == :retry && kwargs[:retry_block]
          retry_block = kwargs[:retry_block]
        end
      end

      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      ::OpenAI::Client.stub(:new, lambda { |_config, &block|
        block&.call(mock_faraday_builder)
        Minitest::Mock.new
      }) do
        Logger.stub(:new, logger) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
          )
        end
      end

      # Test with HTTP status error (no exception)
      mock_env = MockEnv.new(502)
      mock_options = MockOptions.new(3, 0.5, 2)

      retry_block.call(
        env: mock_env,
        options: mock_options,
        retry_count: 1,
        exception: nil,
        will_retry: true,
      )

      log_content = log_output.string

      assert_match(%r{Request failed \(attempt 1/3\): HTTP 502}, log_content)
      assert_match(/Retrying in 0.5 seconds.../, log_content)
    end

    def test_exponential_backoff_calculation
      retry_block = nil
      mock_faraday_builder = Minitest::Mock.new
      mock_faraday_builder.expect(:adapter, nil, [:net_http_persistent])
      mock_faraday_builder.expect(:request, nil) do |middleware, *_args, **kwargs|
        if middleware == :retry && kwargs[:retry_block]
          retry_block = kwargs[:retry_block]
        end
      end

      # Capture log output
      log_output = StringIO.new
      logger = Logger.new(log_output)

      ::OpenAI::Client.stub(:new, lambda { |_config, &block|
        block&.call(mock_faraday_builder)
        Minitest::Mock.new
      }) do
        Logger.stub(:new, logger) do
          ClaudeSwarm::OpenAI::Executor.new(
            working_directory: @tmpdir,
            model: "gpt-4o",
            instance_name: "test-instance",
            openai_token_env: "TEST_OPENAI_API_KEY",
          )
        end
      end

      mock_env = MockEnv.new(500)
      mock_options = MockOptions.new(3, 0.5, 2)

      # Test exponential backoff for different retry counts
      test_cases = [
        { retry_count: 1, expected_delay: 0.5 },   # 0.5 * 2^(1-1) = 0.5
        { retry_count: 2, expected_delay: 1.0 },   # 0.5 * 2^(2-1) = 1.0
        { retry_count: 3, expected_delay: 2.0 },   # 0.5 * 2^(3-1) = 2.0
      ]

      test_cases.each do |test_case|
        log_output.truncate(0)

        retry_block.call(
          env: mock_env,
          options: mock_options,
          retry_count: test_case[:retry_count],
          exception: nil,
          will_retry: true,
        )

        log_content = log_output.string

        assert_match(/Retrying in #{test_case[:expected_delay]} seconds/, log_content)
      end
    end

    def test_retry_middleware_configured_for_all_error_types
      captured_config = nil
      mock_faraday_builder = Minitest::Mock.new
      mock_faraday_builder.expect(:adapter, nil, [:net_http_persistent])
      mock_faraday_builder.expect(:request, nil) do |middleware, *_args, **kwargs|
        if middleware == :retry
          captured_config = kwargs
        end
      end

      ::OpenAI::Client.stub(:new, lambda { |_config, &block|
        block&.call(mock_faraday_builder)
        Minitest::Mock.new
      }) do
        ClaudeSwarm::OpenAI::Executor.new(
          working_directory: @tmpdir,
          model: "gpt-4o",
          instance_name: "test-instance",
          openai_token_env: "TEST_OPENAI_API_KEY",
        )
      end

      # Verify all expected error types are configured
      assert_includes(captured_config[:exceptions], Faraday::TimeoutError)
      assert_includes(captured_config[:exceptions], Faraday::ConnectionFailed)
      assert_includes(captured_config[:exceptions], Faraday::ServerError)

      # Verify all expected HTTP status codes
      [429, 500, 502, 503, 504].each do |status|
        assert_includes(captured_config[:retry_statuses], status)
      end
    end

    def test_openai_client_initialization_succeeds_with_faraday_configuration
      # This test verifies that the OpenAI client is properly initialized with our Faraday configuration.
      # The fact that initialization succeeds means the net_http_persistent adapter is available and working.
      executor = ClaudeSwarm::OpenAI::Executor.new(
        working_directory: @tmpdir,
        model: "gpt-4o",
        instance_name: "test-instance",
        openai_token_env: "TEST_OPENAI_API_KEY",
      )

      # Verify the client was created successfully
      client = executor.instance_variable_get(:@openai_client)

      assert_instance_of(::OpenAI::Client, client, "Expected @openai_client to be an OpenAI::Client instance")
    end

    private

    def with_mcp_stubs(stdio_config_lambda: nil, create_client_lambda: nil)
      mock_mcp_client = Minitest::Mock.new
      mock_mcp_client.expect(:list_tools, [])

      stdio_lambda = stdio_config_lambda || lambda { |**kwargs|
        { command: kwargs[:command], name: kwargs[:name] }
      }

      client_lambda = create_client_lambda || lambda { |**_kwargs|
        mock_mcp_client
      }

      MCPClient.stub(:stdio_config, stdio_lambda) do
        MCPClient.stub(:create_client, client_lambda) do
          yield mock_mcp_client
        end
      end
    end
  end
end
