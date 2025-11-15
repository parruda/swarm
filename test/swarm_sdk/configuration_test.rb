# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "yaml"

module SwarmSDK
  class ConfigurationTest < Minitest::Test
    def setup
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure { |config| config.openai_api_key = "test-key-12345" }
    end

    def teardown
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure { |config| config.openai_api_key = @original_api_key }
    end

    def test_load_valid_configuration
      with_config_file(valid_config) do |path|
        config = Configuration.load_file(path)

        assert_instance_of(Configuration, config)
        assert_equal("Test Swarm", config.swarm_name)
        assert_equal(:lead, config.lead_agent)
        assert_equal(2, config.agents.size)
      end
    end

    def test_missing_configuration_file_raises_error
      error = assert_raises(ConfigurationError) do
        Configuration.load_file("/nonexistent/path.yml")
      end

      assert_match(/configuration file not found/i, error.message)
    end

    def test_invalid_yaml_syntax_raises_error
      with_config_file("invalid: yaml: syntax: [") do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/invalid yaml syntax/i, error.message)
      end
    end

    def test_missing_version_field_raises_error
      config = valid_config
      config.delete("version")

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/missing 'version' field/i, error.message)
      end
    end

    def test_unsupported_version_raises_error
      config = valid_config
      config["version"] = 1

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/version: 2/i, error.message)
      end
    end

    def test_missing_swarm_field_raises_error
      config = { "version" => 2 }

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/missing 'swarm:' or 'workflow:' key/i, error.message)
      end
    end

    def test_missing_name_in_swarm_raises_error
      config = valid_config
      config["swarm"].delete("name")

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/missing 'name' field/i, error.message)
      end
    end

    def test_missing_lead_in_swarm_raises_error
      config = valid_config
      config["swarm"].delete("lead")

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/missing 'lead' field/i, error.message)
      end
    end

    def test_missing_agents_in_swarm_raises_error
      config = valid_config
      config["swarm"].delete("agents")

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/missing 'agents' field/i, error.message)
      end
    end

    def test_empty_agents_raises_error
      config = valid_config
      config["swarm"]["agents"] = {}

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/no agents defined/i, error.message)
      end
    end

    def test_nonexistent_lead_agent_raises_error
      config = valid_config
      config["swarm"]["lead"] = "nonexistent"

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/lead agent.*not found/i, error.message)
      end
    end

    def test_circular_dependency_raises_error
      config = {
        "version" => 2,
        "swarm" => {
          "name" => "Circular",
          "lead" => "agent1",
          "agents" => {
            "agent1" => {
              "description" => "Agent 1",
              "system_prompt" => "Test",
              "delegates_to" => ["agent2"],
              "directory" => ".",
            },
            "agent2" => {
              "description" => "Agent 2",
              "system_prompt" => "Test",
              "delegates_to" => ["agent3"],
              "directory" => ".",
            },
            "agent3" => {
              "description" => "Agent 3",
              "system_prompt" => "Test",
              "delegates_to" => ["agent1"],
              "directory" => ".",
            },
          },
        },
      }

      with_config_file(config) do |path|
        error = assert_raises(CircularDependencyError) do
          Configuration.load_file(path)
        end

        assert_match(/circular dependency detected/i, error.message)
      end
    end

    def test_unknown_connection_raises_error
      config = valid_config
      config["swarm"]["agents"]["lead"]["delegates_to"] = ["nonexistent"]

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/delegates to unknown target/i, error.message)
      end
    end

    def test_deep_symbolization_of_yaml_keys
      with_config_file(valid_config) do |path|
        configuration = Configuration.load_file(path)

        # Test symbolization through public API - agent names should be symbols
        assert(configuration.agent_names.all? { |k| k.is_a?(Symbol) })

        # Test that agents hash has symbol keys
        assert(configuration.agents.keys.all? { |k| k.is_a?(Symbol) })

        # Test that agent config is accessible with symbols
        lead_agent = configuration.agents[:lead]

        assert_instance_of(Hash, lead_agent)
      end
    end

    def test_nested_hash_symbolization
      config = valid_config
      config["swarm"]["agents"]["lead"]["mcp_servers"] = [
        { "type" => "stdio", "command" => "test" },
      ]

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)

        # Test symbolization through public API
        lead_agent = configuration.agents[:lead]
        mcp_servers = lead_agent[:mcp_servers]

        # MCP server configs should have symbol keys
        assert(mcp_servers.first.keys.all? { |k| k.is_a?(Symbol) })
      end
    end

    def test_agent_names_returns_all_agent_names
      with_config_file(valid_config) do |path|
        config = Configuration.load_file(path)

        names = config.agent_names

        assert_equal(2, names.length)
        assert_includes(names, :lead)
        assert_includes(names, :backend)
      end
    end

    def test_connections_for_returns_delegates_to
      with_config_file(valid_config) do |path|
        config = Configuration.load_file(path)

        connections = config.connections_for(:lead)

        assert_equal([:backend], connections)
      end
    end

    def test_connections_for_nonexistent_agent_returns_empty
      with_config_file(valid_config) do |path|
        config = Configuration.load_file(path)

        connections = config.connections_for(:nonexistent)

        assert_empty(connections)
      end
    end

    def test_to_swarm_creates_swarm_instance
      with_config_file(valid_config) do |path|
        config = Configuration.load_file(path)
        swarm = config.to_swarm

        assert_instance_of(Swarm, swarm)
        assert_equal("Test Swarm", swarm.name)
        assert_equal(:lead, swarm.lead_agent)
        assert_equal([:lead, :backend], swarm.agent_names)
      end
    end

    def test_env_var_interpolation
      ENV["TEST_MODEL"] = "gpt-5-turbo"

      config = valid_config
      config["swarm"]["agents"]["lead"]["model"] = "${TEST_MODEL}"

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        lead_agent = configuration.agents[:lead]

        assert_equal("gpt-5-turbo", lead_agent[:model])
      end
    ensure
      ENV.delete("TEST_MODEL")
    end

    def test_env_var_with_default
      config = valid_config
      config["swarm"]["agents"]["lead"]["model"] = "${MISSING_VAR:=default-model}"

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        lead_agent = configuration.agents[:lead]

        assert_equal("default-model", lead_agent[:model])
      end
    end

    def test_missing_env_var_without_default_raises_error
      config = valid_config
      config["swarm"]["agents"]["lead"]["model"] = "${MISSING_VAR_NO_DEFAULT}"

      with_config_file(config) do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/environment variable.*not set/i, error.message)
      end
    end

    def test_load_agent_from_markdown_file
      agent_md = <<~MARKDOWN
        ---
        description: Backend developer
        model: gpt-5
        directory: .
        tools:
          - Read
          - Edit
        ---

        You are a backend developer.
      MARKDOWN

      with_config_file(valid_config) do |_config_path|
        Dir.mktmpdir do |dir|
          agent_file = File.join(dir, "backend.md")
          File.write(agent_file, agent_md)

          # Update config to use agent_file
          config = valid_config
          config["swarm"]["agents"]["backend"] = {
            "agent_file" => agent_file,
          }

          with_config_file(config) do |path|
            configuration = Configuration.load_file(path)

            # Build swarm to load the agent from file
            swarm = configuration.to_swarm
            # Access agent definition directly (doesn't require agent to be created as primary)
            backend_def = swarm.agent_definitions[:backend]

            assert_equal("Backend developer", backend_def.description)
            assert_equal("gpt-5", backend_def.model)
            assert_includes(backend_def.system_prompt, "You are a backend developer")
          end
        end
      end
    end

    def test_load_agent_from_relative_path
      agent_md = <<~MARKDOWN
        ---
        description: Test agent
        directory: .
        ---

        Test prompt.
      MARKDOWN

      Dir.mktmpdir do |dir|
        # Create agent file in subdirectory relative to config
        agents_dir = File.join(dir, "agents")
        FileUtils.mkdir_p(agents_dir)
        agent_file = File.join(agents_dir, "test.md")
        File.write(agent_file, agent_md)

        # Config file in parent directory
        config = valid_config
        config["swarm"]["agents"]["backend"] = {
          "agent_file" => "agents/test.md",
        }

        config_path = File.join(dir, "swarm.yml")
        File.write(config_path, YAML.dump(config))

        configuration = Configuration.load_file(config_path)

        # Build swarm to load the agent from file
        swarm = configuration.to_swarm
        # Access agent definition directly (doesn't require agent to be created as primary)
        backend_def = swarm.agent_definitions[:backend]

        assert_equal("Test agent", backend_def.description)
      end
    end

    def test_load_agent_from_absolute_path
      agent_md = <<~MARKDOWN
        ---
        description: Test agent
        directory: .
        ---

        Test prompt.
      MARKDOWN

      Dir.mktmpdir do |dir|
        agent_file = File.join(dir, "agent.md")
        File.write(agent_file, agent_md)

        config = valid_config
        config["swarm"]["agents"]["backend"] = {
          "agent_file" => agent_file,
        }

        with_config_file(config) do |config_path|
          configuration = Configuration.load_file(config_path)

          # Build swarm to load the agent from file
          swarm = configuration.to_swarm
          # Access agent definition directly (doesn't require agent to be created as primary)
          backend_def = swarm.agent_definitions[:backend]

          assert_equal("Test agent", backend_def.description)
        end
      end
    end

    def test_load_agent_from_nonexistent_file_raises_error
      config = valid_config
      config["swarm"]["agents"]["backend"] = {
        "agent_file" => "/nonexistent/agent.md",
      }

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)

        # Error occurs when building the swarm (loading the agent)
        error = assert_raises(ConfigurationError) do
          configuration.to_swarm
        end

        assert_match(/agent file not found/i, error.message)
      end
    end

    def test_load_agent_from_invalid_markdown_raises_error
      invalid_md = "Just plain text without frontmatter"

      Dir.mktmpdir do |dir|
        agent_file = File.join(dir, "invalid.md")
        File.write(agent_file, invalid_md)

        config = valid_config
        config["swarm"]["agents"]["backend"] = {
          "agent_file" => agent_file,
        }

        with_config_file(config) do |path|
          configuration = Configuration.load_file(path)

          # Error occurs when building the swarm (loading the agent)
          # Error message varies depending on markdown content, but should raise
          assert_raises(ConfigurationError) do
            configuration.to_swarm
          end
        end
      end
    end

    def test_configuration_with_mixed_inline_and_file_agents
      agent_md = <<~MARKDOWN
        ---
        description: File-based agent
        directory: .
        ---

        From file.
      MARKDOWN

      Dir.mktmpdir do |dir|
        agent_file = File.join(dir, "backend.md")
        File.write(agent_file, agent_md)

        config = valid_config
        config["swarm"]["agents"]["backend"] = {
          "agent_file" => agent_file,
        }

        with_config_file(config) do |path|
          configuration = Configuration.load_file(path)

          # lead is inline, backend is from file
          assert_equal(2, configuration.agents.size)

          # Build swarm to load agents from files
          swarm = configuration.to_swarm

          assert_equal("Lead agent", swarm.agent_definitions[:lead].description)
          assert_equal("File-based agent", swarm.agent_definitions[:backend].description)
        end
      end
    end

    def test_env_var_interpolation_in_nested_structures
      ENV["TEST_TEMP"] = "0.8"
      ENV["TEST_TOKENS"] = "2000"

      config = valid_config
      config["swarm"]["agents"]["lead"]["parameters"] = {
        "temperature" => "${TEST_TEMP}",
        "max_tokens" => "${TEST_TOKENS}",
      }

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        lead_agent = configuration.agents[:lead]

        assert_equal("0.8", lead_agent[:parameters][:temperature])
        assert_equal("2000", lead_agent[:parameters][:max_tokens])
      end
    ensure
      ENV.delete("TEST_TEMP")
      ENV.delete("TEST_TOKENS")
    end

    def test_env_var_with_empty_default
      config = valid_config
      config["swarm"]["agents"]["lead"]["base_url"] = "${MISSING_VAR:=}"

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        lead_agent = configuration.agents[:lead]

        assert_equal("", lead_agent[:base_url])
      end
    end

    def test_agent_with_null_config_uses_defaults
      config = valid_config
      config["swarm"]["agents"]["backend"] = nil

      with_config_file(config) do |path|
        # Null agent config should fail strict validation
        assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end
      end
    end

    def test_load_class_method_returns_loaded_configuration
      with_config_file(valid_config) do |path|
        configuration = Configuration.load_file(path)

        assert_instance_of(Configuration, configuration)
        assert_equal("Test Swarm", configuration.swarm_name)
        assert_equal(2, configuration.agents.size)
      end
    end

    def test_configuration_with_agent_delegates_to_symbols
      config = valid_config
      config["swarm"]["agents"]["lead"]["delegates_to"] = ["backend", "frontend"]

      with_config_file(config) do |path|
        Configuration.load_file(path)

        # Should error because frontend doesn't exist
        assert_raises(ConfigurationError) do
          # This error is raised during circular dependency detection
        end
      end
    rescue ConfigurationError => e
      # Expected error about unknown agent
      assert_match(/delegates to unknown target/i, e.message)
    end

    def test_non_hash_yaml_raises_error
      with_config_file("not a hash") do |path|
        error = assert_raises(ConfigurationError) do
          Configuration.load_file(path)
        end

        assert_match(/invalid yaml syntax.*must be a hash/i, error.message)
      end
    end

    def test_configuration_with_mcp_servers
      config = valid_config
      config["swarm"]["agents"]["lead"]["mcp_servers"] = [
        { "type" => "stdio", "command" => "test-server" },
        { "type" => "sse", "url" => "http://localhost:3000" },
      ]

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        lead = configuration.agents[:lead]

        assert_equal(2, lead[:mcp_servers].size)
        # Deep symbolization converts string keys to symbols
        assert_equal("stdio", lead[:mcp_servers][0][:type])
        assert_equal("sse", lead[:mcp_servers][1][:type])
      end
    end

    def test_connections_for_with_empty_array
      config = valid_config
      config["swarm"]["agents"]["backend"]["delegates_to"] = []

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)

        connections = configuration.connections_for(:backend)

        assert_empty(connections)
      end
    end

    def test_agent_names_returns_symbols
      with_config_file(valid_config) do |path|
        config = Configuration.load_file(path)

        names = config.agent_names

        assert(names.all? { |n| n.is_a?(Symbol) })
      end
    end

    def test_configuration_with_empty_delegates_to
      config = valid_config
      config["swarm"]["agents"]["backend"]["delegates_to"] = []

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        backend = configuration.agents[:backend]

        assert_empty(backend[:delegates_to])
      end
    end

    def test_configuration_with_nil_mcp_servers
      config = valid_config
      config["swarm"]["agents"]["lead"]["mcp_servers"] = nil

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)
        lead = configuration.agents[:lead]

        assert_empty(lead[:mcp_servers] || [])
      end
    end

    def test_agents_attribute_returns_hash
      with_config_file(valid_config) do |path|
        configuration = Configuration.load_file(path)

        assert_instance_of(Hash, configuration.agents)
        assert_equal(2, configuration.agents.size)
      end
    end

    def test_load_agent_from_string_path
      agent_md = <<~MARKDOWN
        ---
        description: String path agent
        model: gpt-5
        directory: .
        tools:
          - Read
        ---

        You are loaded from a string path.
      MARKDOWN

      Dir.mktmpdir do |dir|
        agent_file = File.join(dir, "backend.md")
        File.write(agent_file, agent_md)

        # Use string format: agent_name: "path/to/file.md"
        config = valid_config
        config["swarm"]["agents"]["backend"] = agent_file # String, not Hash

        with_config_file(config) do |path|
          configuration = Configuration.load_file(path)

          # Build swarm to load the agent from file
          swarm = configuration.to_swarm
          # Access agent definition directly (doesn't require agent to be created as primary)
          backend_def = swarm.agent_definitions[:backend]

          assert_equal("String path agent", backend_def.description)
          assert_equal("gpt-5", backend_def.model)
          assert_includes(backend_def.system_prompt, "You are loaded from a string path")
        end
      end
    end

    def test_load_agent_from_string_path_relative
      agent_md = <<~MARKDOWN
        ---
        description: Relative string path agent
        directory: .
        ---

        Test prompt.
      MARKDOWN

      Dir.mktmpdir do |dir|
        # Create agent file in subdirectory relative to config
        agents_dir = File.join(dir, "agents")
        FileUtils.mkdir_p(agents_dir)
        agent_file = File.join(agents_dir, "test.md")
        File.write(agent_file, agent_md)

        # Use string format with relative path
        config = valid_config
        config["swarm"]["agents"]["backend"] = "agents/test.md" # String with relative path

        config_path = File.join(dir, "swarm.yml")
        File.write(config_path, YAML.dump(config))

        configuration = Configuration.load_file(config_path)

        # Build swarm to load the agent from file
        swarm = configuration.to_swarm
        # Access agent definition directly (doesn't require agent to be created as primary)
        backend_def = swarm.agent_definitions[:backend]

        assert_equal("Relative string path agent", backend_def.description)
      end
    end

    def test_string_path_with_nonexistent_file_raises_error
      config = valid_config
      config["swarm"]["agents"]["backend"] = "/nonexistent/agent.md" # String path

      with_config_file(config) do |path|
        configuration = Configuration.load_file(path)

        # Error occurs when building the swarm (loading the agent)
        error = assert_raises(ConfigurationError) do
          configuration.to_swarm
        end

        assert_match(/agent file not found/i, error.message)
      end
    end

    def test_mixed_agent_formats_inline_hash_and_string
      agent_md = <<~MARKDOWN
        ---
        description: From string path
        directory: .
        ---

        String path agent.
      MARKDOWN

      Dir.mktmpdir do |dir|
        agent_file = File.join(dir, "backend.md")
        File.write(agent_file, agent_md)

        config = valid_config
        # lead is inline hash, backend is string path
        config["swarm"]["agents"]["backend"] = agent_file

        with_config_file(config) do |path|
          configuration = Configuration.load_file(path)

          assert_equal(2, configuration.agents.size)

          # Build swarm to load agents
          swarm = configuration.to_swarm

          assert_equal("Lead agent", swarm.agent_definitions[:lead].description)
          assert_equal("From string path", swarm.agent_definitions[:backend].description)
        end
      end
    end

    private

    def valid_config
      {
        "version" => 2,
        "swarm" => {
          "name" => "Test Swarm",
          "lead" => "lead",
          "agents" => {
            "lead" => {
              "description" => "Lead agent",
              "system_prompt" => "You are the lead",
              "delegates_to" => ["backend"],
              "directory" => ".",
              "tools" => ["Read", "Edit"],
            },
            "backend" => {
              "description" => "Backend agent",
              "system_prompt" => "You build APIs",
              "delegates_to" => [],
              "directory" => ".",
              "tools" => ["Read", "Edit", "Bash"],
            },
          },
        },
      }
    end

    def with_config_file(config)
      Tempfile.create(["swarm-test", ".yml"]) do |file|
        file.write(YAML.dump(config))
        file.flush
        yield file.path
      end
    end
  end
end
