# frozen_string_literal: true

require "test_helper"

class McpGeneratorArgsTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @session_path = File.join(@tmpdir, "test_session")
    ENV["CLAUDE_SWARM_SESSION_PATH"] = @session_path

    @config_content = <<~YAML
      version: 1
      swarm:
        name: "Test Swarm"
        main: lead
        instances:
          lead:
            description: "Lead developer instance"
            directory: .
            model: opus
            connections: [backend]
            tools: [Read, Edit]
            prompt: "You are the lead"
          backend:
            description: "Backend developer instance"
            directory: ./backend
            model: sonnet
            tools: [Bash, Grep]
            prompt: "You are a backend dev"
    YAML
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    ENV.delete("CLAUDE_SWARM_SESSION_PATH")
  end

  def test_mcp_config_generates_correct_args
    Dir.mktmpdir do |tmpdir|
      # Write the config file
      config_path = File.join(tmpdir, "claude-swarm.yml")
      File.write(config_path, @config_content)

      # Create required directories
      Dir.mkdir(File.join(tmpdir, "backend"))

      # Create the configuration and generator
      config = ClaudeSwarm::Configuration.new(config_path, base_dir: tmpdir)
      generator = ClaudeSwarm::McpGenerator.new(config)

      # Generate MCP configs
      generator.generate_all

      # Read the lead instance MCP config
      lead_config = read_mcp_config("lead")

      # Check that backend connection uses correct args format
      backend_mcp = lead_config["mcpServers"]["backend"]

      assert_equal("stdio", backend_mcp["type"])
      assert_equal("claude-swarm", backend_mcp["command"])

      # Verify the args array
      args = backend_mcp["args"]

      # Should start with mcp-serve command
      assert_equal("mcp-serve", args[0])

      # Should have pairs of flag and value
      assert_includes(args, "--name")
      assert_includes(args, "backend")
      assert_includes(args, "--directory")
      assert_includes(args, File.join(tmpdir, "backend"))
      assert_includes(args, "--model")
      assert_includes(args, "sonnet")
      assert_includes(args, "--prompt")
      assert_includes(args, "You are a backend dev")
      assert_includes(args, "--allowed-tools")

      # Tools should be after --allowed-tools flag as comma-separated
      tools_index = args.index("--allowed-tools")

      assert_equal("Bash,Grep", args[tools_index + 1])

      # Should include MCP config path
      assert_includes(args, "--mcp-config-path")
      assert(args[args.index("--mcp-config-path") + 1].end_with?("backend.mcp.json"))
    end
  end

  def test_mcp_config_with_openai_provider_args
    openai_config = <<~YAML
      version: 1
      swarm:
        name: "OpenAI Test Swarm"
        main: lead
        instances:
          lead:
            description: "Lead developer"
            directory: .
            model: opus
            connections: [ai_helper]
          ai_helper:
            description: "AI helper using OpenAI"
            directory: .
            provider: openai
            model: gpt-4o
            temperature: 0.7
            api_version: responses
            openai_token_env: CUSTOM_OPENAI_KEY
            base_url: https://custom.openai.com/v1
    YAML

    Dir.mktmpdir do |tmpdir|
      # Write the config file
      config_path = File.join(tmpdir, "claude-swarm.yml")
      File.write(config_path, openai_config)

      # Set environment variable for test
      ENV["CUSTOM_OPENAI_KEY"] = "sk-test-key"

      # Create the configuration and generator
      config = ClaudeSwarm::Configuration.new(config_path, base_dir: tmpdir)
      generator = ClaudeSwarm::McpGenerator.new(config)

      # Generate MCP configs
      generator.generate_all

      # Read the lead instance MCP config
      lead_config = read_mcp_config("lead")

      # Check that ai_helper connection includes OpenAI provider args
      ai_helper_mcp = lead_config["mcpServers"]["ai_helper"]
      args = ai_helper_mcp["args"]

      # Should include provider and OpenAI-specific args
      assert_includes(args, "--provider")
      assert_includes(args, "openai")
      assert_includes(args, "--temperature")
      assert_includes(args, "0.7")
      assert_includes(args, "--api-version")
      assert_includes(args, "responses")
      assert_includes(args, "--openai-token-env")
      assert_includes(args, "CUSTOM_OPENAI_KEY")
      assert_includes(args, "--base-url")
      assert_includes(args, "https://custom.openai.com/v1")

      # Should have vibe flag for OpenAI instances
      assert_includes(args, "--vibe")
    end
  end

  def test_mcp_config_without_provider_no_openai_args
    Dir.mktmpdir do |tmpdir|
      # Write the config file (default Claude provider)
      config_path = File.join(tmpdir, "claude-swarm.yml")
      File.write(config_path, @config_content)

      # Create required directories
      Dir.mkdir(File.join(tmpdir, "backend"))

      # Create the configuration and generator
      config = ClaudeSwarm::Configuration.new(config_path, base_dir: tmpdir)
      generator = ClaudeSwarm::McpGenerator.new(config)

      # Generate MCP configs
      generator.generate_all

      # Read the lead instance MCP config
      lead_config = read_mcp_config("lead")

      # Check that backend connection doesn't have OpenAI args
      backend_mcp = lead_config["mcpServers"]["backend"]
      args = backend_mcp["args"]

      # Should NOT include OpenAI-specific args
      refute_includes(args, "--provider")
      refute_includes(args, "--temperature")
      refute_includes(args, "--api-version")
      refute_includes(args, "--openai-token-env")
      refute_includes(args, "--base-url")
    end
  ensure
    ENV.delete("CUSTOM_OPENAI_KEY")
  end

  def test_mcp_config_with_zdr_parameter
    # Test with zdr: true
    openai_config_with_zdr_true = <<~YAML
      version: 1
      swarm:
        name: "ZDR Test Swarm"
        main: lead
        instances:
          lead:
            description: "Lead developer"
            directory: .
            model: opus
            connections: [reasoning_helper]
          reasoning_helper:
            description: "AI with deep reasoning"
            directory: .
            provider: openai
            model: gpt-4o-reasoning
            api_version: responses
            openai_token_env: TEST_OPENAI_KEY
            reasoning_effort: high
            zdr: true
    YAML

    Dir.mktmpdir do |tmpdir|
      # Write the config file
      config_path = File.join(tmpdir, "claude-swarm.yml")
      File.write(config_path, openai_config_with_zdr_true)

      # Set environment variable for test
      ENV["TEST_OPENAI_KEY"] = "sk-test-key"

      # Create the configuration and generator
      config = ClaudeSwarm::Configuration.new(config_path, base_dir: tmpdir)
      generator = ClaudeSwarm::McpGenerator.new(config)

      # Generate MCP configs
      generator.generate_all

      # Read the lead instance MCP config
      lead_config = read_mcp_config("lead")

      # Check that reasoning_helper connection includes zdr arg
      reasoning_helper_mcp = lead_config["mcpServers"]["reasoning_helper"]
      args = reasoning_helper_mcp["args"]

      # Should include zdr flag with value "true"
      assert_includes(args, "--zdr")
      zdr_index = args.index("--zdr")

      assert_equal("true", args[zdr_index + 1])

      # Should also include reasoning_effort
      assert_includes(args, "--reasoning-effort")
      assert_includes(args, "high")

      # Should include the correct openai_token_env
      assert_includes(args, "--openai-token-env")
      assert_includes(args, "TEST_OPENAI_KEY")
    end

    # Test with zdr: false
    openai_config_with_zdr_false = <<~YAML
      version: 1
      swarm:
        name: "ZDR False Test Swarm"
        main: lead
        instances:
          lead:
            description: "Lead developer"
            directory: .
            model: opus
            connections: [standard_helper]
          standard_helper:
            description: "Standard AI helper"
            directory: .
            provider: openai
            model: gpt-4o
            openai_token_env: TEST_OPENAI_KEY
            zdr: false
    YAML

    Dir.mktmpdir do |tmpdir|
      # Write the config file
      config_path = File.join(tmpdir, "claude-swarm.yml")
      File.write(config_path, openai_config_with_zdr_false)

      # Set environment variable for test
      ENV["TEST_OPENAI_KEY"] = "sk-test-key"

      # Create the configuration and generator
      config = ClaudeSwarm::Configuration.new(config_path, base_dir: tmpdir)
      generator = ClaudeSwarm::McpGenerator.new(config)

      # Generate MCP configs
      generator.generate_all

      # Read the lead instance MCP config
      lead_config = read_mcp_config("lead")

      # Check that standard_helper connection includes zdr arg with false
      standard_helper_mcp = lead_config["mcpServers"]["standard_helper"]
      args = standard_helper_mcp["args"]

      # Should include zdr flag with value "false"
      assert_includes(args, "--zdr")
      zdr_index = args.index("--zdr")

      assert_equal("false", args[zdr_index + 1])
    end

    # Test without zdr parameter (should not include --zdr)
    openai_config_without_zdr = <<~YAML
      version: 1
      swarm:
        name: "No ZDR Test Swarm"
        main: lead
        instances:
          lead:
            description: "Lead developer"
            directory: .
            model: opus
            connections: [basic_helper]
          basic_helper:
            description: "Basic AI helper"
            directory: .
            provider: openai
            model: gpt-4o
            openai_token_env: TEST_OPENAI_KEY
    YAML

    Dir.mktmpdir do |tmpdir|
      # Write the config file
      config_path = File.join(tmpdir, "claude-swarm.yml")
      File.write(config_path, openai_config_without_zdr)

      # Set environment variable for test
      ENV["TEST_OPENAI_KEY"] = "sk-test-key"

      # Create the configuration and generator
      config = ClaudeSwarm::Configuration.new(config_path, base_dir: tmpdir)
      generator = ClaudeSwarm::McpGenerator.new(config)

      # Generate MCP configs
      generator.generate_all

      # Read the lead instance MCP config
      lead_config = read_mcp_config("lead")

      # Check that basic_helper connection does NOT include zdr arg
      basic_helper_mcp = lead_config["mcpServers"]["basic_helper"]
      args = basic_helper_mcp["args"]

      # Should NOT include zdr flag when not specified
      refute_includes(args, "--zdr")
    end
  ensure
    ENV.delete("TEST_OPENAI_KEY")
  end
end
