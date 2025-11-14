# frozen_string_literal: true

require "test_helper"

class CLITest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @cli = ClaudeSwarm::CLI.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def write_config(filename, content)
    path = File.join(@tmpdir, filename)
    File.write(path, content)
    path
  end

  def capture_cli_output(&)
    capture_io(&)
  end

  def test_exit_on_failure
    assert_predicate(ClaudeSwarm::CLI, :exit_on_failure?)
  end

  def test_version_command
    output, = capture_cli_output { @cli.version }

    assert_match(/Claude Swarm \d+\.\d+\.\d+/, output)
  end

  def test_default_task_is_start
    assert_equal("start", ClaudeSwarm::CLI.default_task)
  end

  def test_start_with_missing_config_file
    assert_raises(SystemExit) do
      capture_cli_output { @cli.start("nonexistent.yml") }
    end
  end

  def test_start_with_invalid_yaml
    config_path = write_config("invalid.yml", "invalid: yaml: syntax:")

    assert_raises(SystemExit) do
      capture_cli_output { @cli.start(config_path) }
    end
  end

  def test_start_with_configuration_error
    config_path = write_config("bad-config.yml", <<~YAML)
      version: 2
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
      #{"      "}
    YAML

    _, err = capture_cli_output do
      assert_raises(SystemExit) { @cli.start(config_path) }
    end

    assert_match(/Unsupported version/, err)
  end

  def test_start_with_valid_config
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
      #{"      "}
    YAML

    # Mock the orchestrator to prevent actual execution
    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    ClaudeSwarm::Orchestrator.stub(:new, orchestrator_mock) do
      capture_cli_output { @cli.start(config_path) }
    end

    orchestrator_mock.verify
  end

  def test_start_with_options
    config_path = write_config("custom.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
      #{"      "}
    YAML

    @cli.options = {}

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    ClaudeSwarm::Orchestrator.stub(:new, orchestrator_mock) do
      capture_cli_output { @cli.start(config_path) }
    end

    orchestrator_mock.verify
  end

  def test_start_with_prompt_option
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"

    YAML

    @cli.options = { prompt: "Test prompt for non-interactive mode" }

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    generator_mock = Minitest::Mock.new

    # Verify that prompt is passed to orchestrator
    ClaudeSwarm::McpGenerator.stub(:new, generator_mock) do
      ClaudeSwarm::Orchestrator.stub(:new, lambda { |_config, _generator, **options|
        assert_equal("Test prompt for non-interactive mode", options[:prompt])
        assert_nil(options[:vibe])
        orchestrator_mock
      }) do
        output, = capture_cli_output { @cli.start(config_path) }
        # Verify that startup message is suppressed when prompt is provided
        refute_match(/Starting Claude Swarm/, output)
      end
    end

    orchestrator_mock.verify
  end

  def test_start_without_prompt_shows_message
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
      #{"      "}
    YAML

    @cli.options = {}

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    ClaudeSwarm::Orchestrator.stub(:new, orchestrator_mock) do
      output, = capture_cli_output { @cli.start(config_path) }
      # Verify that startup message is shown when prompt is not provided
      # The path is now expanded to absolute path
      assert_match(/Starting Claude Swarm from.*valid\.yml\.\.\./, output)
    end

    orchestrator_mock.verify
  end

  def test_mcp_serve_with_all_options
    @cli.options = {
      name: "test_instance",
      directory: "/test/dir",
      model: "opus",
      prompt: "Test prompt",
      allowed_tools: ["Read", "Edit"],
      mcp_config_path: "/path/to/mcp.json",
      debug: false,
      calling_instance: "parent_instance",
    }

    server_mock = Minitest::Mock.new
    server_mock.expect(:start, nil)

    expected_config = {
      name: "test_instance",
      directory: "/test/dir",
      directories: ["/test/dir"],
      model: "opus",
      prompt: "Test prompt",
      description: nil,
      allowed_tools: ["Read", "Edit"],
      disallowed_tools: [],
      connections: [],
      mcp_config_path: "/path/to/mcp.json",
      vibe: false,
      instance_id: nil,
      claude_session_id: nil,
      provider: nil,
      temperature: nil,
      api_version: nil,
      openai_token_env: nil,
      base_url: nil,
      reasoning_effort: nil,
      zdr: nil, # nil when not explicitly set in options
    }

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |config, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      assert_equal(expected_config, config)
      assert_equal("parent_instance", calling_instance)
      server_mock
    }) do
      @cli.mcp_serve
    end

    server_mock.verify
  end

  def test_mcp_serve_with_zdr_true
    @cli.options = {
      name: "zdr_instance",
      directory: @tmpdir,
      model: "gpt-4o-reasoning",
      calling_instance: "parent",
      provider: "openai",
      api_version: "responses",
      zdr: true,
      reasoning_effort: "high",
    }

    server_mock = Minitest::Mock.new
    server_mock.expect(:start, nil)

    expected_config = {
      name: "zdr_instance",
      directory: @tmpdir,
      directories: [@tmpdir],
      model: "gpt-4o-reasoning",
      prompt: nil,
      description: nil,
      allowed_tools: [],
      disallowed_tools: [],
      connections: [],
      mcp_config_path: nil,
      vibe: false,
      instance_id: nil,
      claude_session_id: nil,
      provider: "openai",
      temperature: nil,
      api_version: "responses",
      openai_token_env: nil,
      base_url: nil,
      reasoning_effort: "high",
      zdr: true,
    }

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |config, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      assert_equal(expected_config, config)
      assert_equal("parent", calling_instance)
      assert_nil(debug) # debug is nil when not specified
      server_mock
    }) do
      @cli.mcp_serve
    end

    server_mock.verify
  end

  def test_mcp_serve_with_zdr_false
    @cli.options = {
      name: "no_zdr_instance",
      directory: @tmpdir,
      model: "gpt-4o",
      calling_instance: "parent",
      provider: "openai",
      zdr: false,
    }

    server_mock = Minitest::Mock.new
    server_mock.expect(:start, nil)

    expected_config = {
      name: "no_zdr_instance",
      directory: @tmpdir,
      directories: [@tmpdir],
      model: "gpt-4o",
      prompt: nil,
      description: nil,
      allowed_tools: [],
      disallowed_tools: [],
      connections: [],
      mcp_config_path: nil,
      vibe: false,
      instance_id: nil,
      claude_session_id: nil,
      provider: "openai",
      temperature: nil,
      api_version: nil,
      openai_token_env: nil,
      base_url: nil,
      reasoning_effort: nil,
      zdr: false,
    }

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |config, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      assert_equal(expected_config, config)
      assert_equal("parent", calling_instance)
      assert_nil(debug) # debug is nil when not specified
      server_mock
    }) do
      @cli.mcp_serve
    end

    server_mock.verify
  end

  def test_start_with_root_dir_resolves_relative_paths
    # Create a project structure
    project_dir = File.join(@tmpdir, "my-project")
    config_dir = File.join(project_dir, "configs")
    FileUtils.mkdir_p(config_dir)

    # Create a valid config file
    config_file = File.join(config_dir, "swarm.yml")
    File.write(config_file, valid_test_config)

    # Create another directory to run from
    run_dir = File.join(@tmpdir, "run-from-here")
    FileUtils.mkdir_p(run_dir)

    # Set root_dir to the project directory
    @cli.options = {
      root_dir: project_dir,
      prompt: "test", # Non-interactive mode to avoid exec
    }

    # Mock only the Orchestrator to prevent actual execution
    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    # Let Configuration and McpGenerator run for real
    ClaudeSwarm::Orchestrator.stub(:new, lambda { |config, generator, **_opts|
      # Verify that config was loaded from the correct path
      assert_instance_of(ClaudeSwarm::Configuration, config)
      assert_equal("Test Swarm", config.swarm["name"])
      assert_equal("lead", config.swarm["main"])

      # Verify the generator received the real config
      assert_instance_of(ClaudeSwarm::McpGenerator, generator)

      orchestrator_mock
    }) do
      # This should successfully find and load configs/swarm.yml relative to project_dir
      output, = capture_cli_output { @cli.start("configs/swarm.yml") }

      # The file should be found and loaded
      refute_match(/Configuration file not found/, output)
    end
  end

  def test_start_with_root_dir_file_not_found
    @cli.options = { root_dir: @tmpdir }

    # Should exit with error when file doesn't exist
    # Error messages now go to stderr
    _, err = capture_io do
      assert_raises(SystemExit) { @cli.start("nonexistent.yml") }
    end
    # Check that error message contains the expected text
    assert_match(/Configuration file not found/, err)
  end

  def test_start_with_absolute_path_ignores_root_dir
    # Create config in one location
    config_file = File.join(@tmpdir, "config.yml")
    File.write(config_file, valid_test_config)

    # Set root_dir to a different location
    other_dir = File.join(@tmpdir, "other")
    FileUtils.mkdir_p(other_dir)

    @cli.options = {
      root_dir: other_dir,
      prompt: "test",
    }

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    ClaudeSwarm::Orchestrator.stub(:new, lambda { |config, _generator, **_opts|
      # Should load config from the absolute path, not from other_dir
      assert_instance_of(ClaudeSwarm::Configuration, config)
      assert_equal("Test Swarm", config.swarm["name"])
      orchestrator_mock
    }) do
      # Absolute path should work regardless of root_dir
      output, = capture_cli_output { @cli.start(config_file) }

      refute_match(/Configuration file not found/, output)
    end
  end

  def test_start_without_root_dir_uses_current_directory
    config_file = "relative/path/config.yml"
    full_config_path = File.join(@tmpdir, config_file)

    # Create the directory structure
    FileUtils.mkdir_p(File.dirname(full_config_path))

    # Write valid config
    File.write(full_config_path, valid_test_config)

    # No root_dir option set - should use current directory
    @cli.options = { prompt: "test" }

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    # Mock Dir.pwd to return @tmpdir
    Dir.stub(:pwd, @tmpdir) do
      ClaudeSwarm::Orchestrator.stub(:new, lambda { |config, _generator, **_opts|
        # Verify config was loaded from current directory
        assert_instance_of(ClaudeSwarm::Configuration, config)
        assert_equal("Test Swarm", config.swarm["name"])
        orchestrator_mock
      }) do
        output, = capture_cli_output { @cli.start(config_file) }

        refute_match(/Configuration file not found/, output)
      end
    end
  end

  def test_mcp_serve_with_minimal_options
    @cli.options = {
      name: "minimal",
      directory: ".",
      model: "sonnet",
      calling_instance: "test_caller",
    }

    server_mock = Minitest::Mock.new
    server_mock.expect(:start, nil)

    expected_config = {
      name: "minimal",
      directory: ".",
      directories: ["."],
      model: "sonnet",
      prompt: nil,
      description: nil,
      allowed_tools: [],
      disallowed_tools: [],
      connections: [],
      mcp_config_path: nil,
      vibe: false,
      instance_id: nil,
      claude_session_id: nil,
      provider: nil,
      temperature: nil,
      api_version: nil,
      openai_token_env: nil,
      base_url: nil,
      reasoning_effort: nil,
      zdr: nil,
    }

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |config, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      assert_equal(expected_config, config)
      assert_equal("test_caller", calling_instance)
      server_mock
    }) do
      @cli.mcp_serve
    end

    server_mock.verify
  end

  def test_mcp_serve_error_handling
    @cli.options = {
      name: "error",
      directory: ".",
      model: "sonnet",
      debug: false,
      calling_instance: "test_caller",
    }

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |_, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      raise StandardError, "Test error"
    }) do
      _, err = capture_cli_output do
        assert_raises(SystemExit) { @cli.mcp_serve }
      end

      assert_match(/Error starting MCP server: Test error/, err)
      refute_match(/backtrace/, err) # Debug is false
    end
  end

  def test_mcp_serve_error_with_debug
    @cli.options = {
      name: "error",
      directory: ".",
      model: "sonnet",
      debug: true,
      calling_instance: "test_caller",
    }

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |_, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      raise StandardError, "Test error"
    }) do
      _, err = capture_cli_output do
        assert_raises(SystemExit) { @cli.mcp_serve }
      end

      assert_match(/Error starting MCP server: Test error/, err)
      assert_match(/cli_test\.rb/, err) # Should show backtrace
    end
  end

  def test_mcp_serve_with_reasoning_effort
    @cli.options = {
      name: "test",
      directory: ".",
      model: "o3-pro",
      provider: "openai",
      reasoning_effort: "medium",
      calling_instance: "test_caller",
    }

    server_mock = Minitest::Mock.new
    server_mock.expect(:start, nil)

    ClaudeSwarm::ClaudeMcpServer.stub(:new, lambda { |config, calling_instance:, calling_instance_id: nil, debug: nil| # rubocop:disable Lint/UnusedBlockArgument
      assert_equal("medium", config[:reasoning_effort])
      assert_equal("o3-pro", config[:model])
      server_mock
    }) do
      @cli.mcp_serve
    end

    server_mock.verify
  end

  def test_mcp_serve_with_reasoning_effort_invalid_provider
    @cli.options = {
      name: "test",
      directory: ".",
      model: "sonnet",
      provider: "claude",
      reasoning_effort: "low",
      calling_instance: "test_caller",
    }

    _, err = capture_cli_output do
      assert_raises(SystemExit) { @cli.mcp_serve }
    end

    assert_match(/reasoning_effort is only supported for OpenAI models/, err)
  end

  def test_mcp_serve_with_reasoning_effort_invalid_value
    @cli.options = {
      name: "test",
      directory: ".",
      model: "o3",
      provider: "openai",
      reasoning_effort: "extreme",
      calling_instance: "test_caller",
    }

    _, err = capture_cli_output do
      assert_raises(SystemExit) { @cli.mcp_serve }
    end

    assert_match(/reasoning_effort must be 'low', 'medium', or 'high'/, err)
  end

  def test_start_unexpected_error_without_verbose
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
      #{"      "}
    YAML

    @cli.options = { verbose: false }

    ClaudeSwarm::Configuration.stub(:new, lambda { |_, _|
      raise StandardError, "Unexpected test error"
    }) do
      _, err = capture_cli_output do
        assert_raises(SystemExit) { @cli.start(config_path) }
      end

      assert_match(/Unexpected error: Unexpected test error/, err)
      refute_match(/backtrace/, err)
    end
  end

  def test_start_unexpected_error_with_verbose
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
      #{"      "}
    YAML

    @cli.options = { verbose: true }

    ClaudeSwarm::Configuration.stub(:new, lambda { |_, _|
      raise StandardError, "Unexpected test error"
    }) do
      _, err = capture_cli_output do
        assert_raises(SystemExit) { @cli.start(config_path) }
      end

      assert_match(/Unexpected error: Unexpected test error/, err)
      assert_match(/cli_test\.rb/, err) # Should show backtrace
    end
  end

  def test_cli_help_messages
    # Skip these tests as they depend on the executable being in the PATH
    skip("Skipping executable tests")
  end

  def test_start_help
    # Skip these tests as they depend on the executable being in the PATH
    skip("Skipping executable tests")
  end

  def test_mcp_serve_help
    # Skip these tests as they depend on the executable being in the PATH
    skip("Skipping executable tests")
  end

  def test_generate_without_claude_installed
    # Mock system call to simulate Claude not being installed (command -v fails)
    status = Minitest::Mock.new
    status.expect(:success?, false)
    status.expect(:exitstatus, 1)

    @cli.stub(:system, lambda { |cmd|
      !cmd.include?("command -v claude")
    }) do
      @cli.stub(:last_status, status) do
        _, err = capture_cli_output do
          assert_raises(SystemExit) { @cli.generate }
        end

        assert_match(/Claude CLI is not installed or not in PATH/, err)
        assert_match(/To install Claude CLI, visit:/, err)
      end
    end
    status.verify
  end

  def test_generate_with_claude_installed
    # Mock system call to simulate Claude being installed (command -v succeeds)
    # Create a mock status object for successful command
    success_status = Minitest::Mock.new
    success_status.expect(:success?, true)

    @cli.stub(:system, lambda { |cmd|
      cmd.include?("command -v claude") || false
    }) do
      @cli.stub(:last_status, success_status) do
        # Read the actual template file before stubbing
        actual_template_path = File.expand_path("../lib/claude_swarm/templates/generation_prompt.md.erb", __dir__)
        template_content = File.read(actual_template_path)
        # Mock File operations for README and template
        File.stub(:exist?, ->(path) { path.include?("README.md") || path.include?("generation_prompt.md.erb") }) do
          File.stub(:read, lambda { |path|
            if path.include?("README.md")
              "Mock README content"
            elsif path.include?("generation_prompt.md.erb")
              template_content
            else
              ""
            end
          }) do
            # Stub exec to prevent actual execution and capture the command
            exec_called = false
            exec_args = nil

            @cli.stub(:exec, lambda { |*args|
              exec_called = true
              exec_args = args
              # Prevent actual exec
              nil
            }) do
              @cli.options = { model: "sonnet" }
              @cli.generate

              assert(exec_called, "exec should have been called")
              assert_equal("claude", exec_args[0])
              assert_equal("--model", exec_args[1])
              assert_equal("sonnet", exec_args[2])
              # Test that the prompt includes README content
              assert_match(%r{<full_readme>.*Mock README content.*</full_readme>}m, exec_args[3])
            end
          end
        end
      end
    end
    success_status.verify
  end

  def test_generate_without_output_file_includes_naming_instructions
    # Create a mock status object for successful command
    success_status = Minitest::Mock.new
    success_status.expect(:success?, true)

    @cli.stub(:system, true) do
      @cli.stub(:last_status, success_status) do
        exec_args = nil

        @cli.stub(:exec, lambda { |*args|
          exec_args = args
          nil
        }) do
          @cli.options = { model: "sonnet" }
          @cli.generate

          # Check that the prompt includes instructions to name based on function
          assert_match(/name the file based on the swarm's function/, exec_args[3])
          assert_match(/web-dev-swarm\.yml/, exec_args[3])
          assert_match(/data-pipeline-swarm\.yml/, exec_args[3])
        end
      end
    end
    success_status.verify
  end

  def test_generate_with_custom_output_file
    # Create a mock status object for successful command
    success_status = Minitest::Mock.new
    success_status.expect(:success?, true)

    @cli.stub(:system, true) do
      @cli.stub(:last_status, success_status) do
        exec_args = nil

        @cli.stub(:exec, lambda { |*args|
          exec_args = args
          nil
        }) do
          @cli.options = { output: "my-custom-config.yml", model: "sonnet" }
          @cli.generate

          # Check that the custom output file is mentioned in the prompt
          assert_match(/save it to: my-custom-config\.yml/, exec_args[3])
        end
      end
    end
    success_status.verify
  end

  def test_generate_with_custom_model
    # Create a mock status object for successful command
    success_status = Minitest::Mock.new
    success_status.expect(:success?, true)

    @cli.stub(:system, true) do
      @cli.stub(:last_status, success_status) do
        exec_args = nil

        @cli.stub(:exec, lambda { |*args|
          exec_args = args
          nil
        }) do
          @cli.options = { output: "claude-swarm.yml", model: "opus" }
          @cli.generate

          assert_equal("opus", exec_args[2])
        end
      end
    end
    success_status.verify
  end

  def test_generate_includes_readme_content_if_exists
    # Create a mock README file
    readme_content = "# Claude Swarm\nThis is a test README content."

    # Read the actual template file before stubbing
    actual_template_path = File.expand_path("../lib/claude_swarm/templates/generation_prompt.md.erb", __dir__)
    template_content = File.read(actual_template_path)

    # Create a mock status object for successful command
    success_status = Minitest::Mock.new
    success_status.expect(:success?, true)

    File.stub(:exist?, ->(path) { path.include?("README.md") || path.include?("generation_prompt.md.erb") }) do
      File.stub(:read, lambda { |path|
        if path.include?("README.md")
          readme_content
        elsif path.include?("generation_prompt.md.erb")
          template_content
        else
          ""
        end
      }) do
        @cli.stub(:system, true) do
          @cli.stub(:last_status, success_status) do
            exec_args = nil

            @cli.stub(:exec, lambda { |*args|
              exec_args = args
              nil
            }) do
              @cli.options = { model: "sonnet" }
              @cli.generate

              # The prompt should include the README content in full_readme tags
              assert_match(%r{<full_readme>.*# Claude Swarm.*This is a test README content.*</full_readme>}m, exec_args[3])
            end
          end
        end
      end
    end
    success_status.verify
  end

  def test_build_generation_prompt_with_output_file
    readme_content = "Test README content for Claude Swarm"
    prompt = @cli.send(:build_generation_prompt, readme_content, "output.yml")

    # Test that a prompt is generated
    assert_kind_of(String, prompt)
    assert_operator(prompt.length, :>, 100)

    # Test that output file is mentioned
    assert_match(/output\.yml/, prompt)

    # Test that README content is included
    assert_match(%r{<full_readme>.*Test README content for Claude Swarm.*</full_readme>}m, prompt)
  end

  def test_build_generation_prompt_without_output_file
    readme_content = "Test README content"
    prompt = @cli.send(:build_generation_prompt, readme_content, nil)

    # Test that a prompt is generated
    assert_kind_of(String, prompt)
    assert_operator(prompt.length, :>, 100)

    # Test that it includes file naming instructions when no output specified
    assert_match(/name the file based on the swarm's function/, prompt)

    # Test that README content is included
    assert_match(%r{<full_readme>.*Test README content.*</full_readme>}m, prompt)
  end

  def test_start_with_session_id_option
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
    YAML

    @cli.options = { session_id: "custom-session-456" }

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    generator_mock = Minitest::Mock.new

    # Verify that session_id is passed to orchestrator
    ClaudeSwarm::McpGenerator.stub(:new, generator_mock) do
      ClaudeSwarm::Orchestrator.stub(:new, lambda { |_config, _generator, **options|
        assert_equal("custom-session-456", options[:session_id])
        orchestrator_mock
      }) do
        capture_cli_output { @cli.start(config_path) }
      end
    end

    orchestrator_mock.verify
  end

  def test_start_with_multiple_options_including_session_id
    config_path = write_config("valid.yml", <<~YAML)
      version: 1
      swarm:
        name: "Test"
        main: lead
        instances:
          lead:
            description: "Test instance"
    YAML

    @cli.options = {
      session_id: "multi-option-test-789",
      vibe: true,
      prompt: "Test with multiple options",
      debug: true,
    }

    orchestrator_mock = Minitest::Mock.new
    orchestrator_mock.expect(:start, nil)

    generator_mock = Minitest::Mock.new

    # Verify all options are passed correctly
    ClaudeSwarm::McpGenerator.stub(:new, generator_mock) do
      ClaudeSwarm::Orchestrator.stub(:new, lambda { |_config, _generator, **options|
        assert_equal("multi-option-test-789", options[:session_id])
        assert(options[:vibe])
        assert_equal("Test with multiple options", options[:prompt])
        assert(options[:debug])
        orchestrator_mock
      }) do
        capture_cli_output { @cli.start(config_path) }
      end
    end

    orchestrator_mock.verify
  end

  private

  def valid_test_config
    <<~YAML
      version: 1
      swarm:
        name: "Test Swarm"
        main: lead
        instances:
          lead:
            description: "Test lead instance"
            directory: .
            model: sonnet
    YAML
  end
end
