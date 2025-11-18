# frozen_string_literal: true

require "test_helper"
require "swarm_cli"
require "swarm_sdk"

class ConfigLoaderTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_load_yaml_config_with_yml_extension
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, <<~YAML)
      version: 2
      swarm:
        name: "Test Team"
        lead: backend
        agents:
          backend:
            description: "Backend developer"
            model: gpt-4
            system_prompt: "You build APIs"
            tools: [Read, Write]
    YAML

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Test Team", swarm.name)
    assert_equal(:backend, swarm.lead_agent)
    assert_includes(swarm.agent_names, :backend)
  end

  def test_load_yaml_config_with_yaml_extension
    config_path = File.join(@tmpdir, "config.yaml")
    File.write(config_path, <<~YAML)
      version: 2
      swarm:
        name: "Dev Team"
        lead: frontend
        agents:
          frontend:
            description: "Frontend developer"
            model: gpt-4
            system_prompt: "You build UIs"
    YAML

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Dev Team", swarm.name)
    assert_equal(:frontend, swarm.lead_agent)
  end

  def test_load_ruby_dsl_config_with_swarm_build
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      SwarmSDK.build do
        name "Ruby DSL Team"
        lead :backend

        agent :backend do
          model "gpt-4"
          description "Backend developer"
          system_prompt "You build APIs"
          tools :Read, :Write
        end
      end
    RUBY

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Ruby DSL Team", swarm.name)
    assert_equal(:backend, swarm.lead_agent)
    assert_includes(swarm.agent_names, :backend)
  end

  def test_load_ruby_dsl_config_with_multiple_agents
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      SwarmSDK.build do
        name "Multi-Agent Team"
        lead :architect

        agent :architect do
          model "gpt-4"
          description "System architect"
          system_prompt "You design systems"
          tools :Read, :Write, :Edit
          delegates_to :backend, :frontend
        end

        agent :backend do
          model "gpt-4"
          description "Backend developer"
          system_prompt "You build APIs"
          tools :Read, :Write, :Bash
        end

        agent :frontend do
          model "gpt-4"
          description "Frontend developer"
          system_prompt "You build UIs"
          tools :Read, :Write, :Bash
        end
      end
    RUBY

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Multi-Agent Team", swarm.name)
    assert_equal(:architect, swarm.lead_agent)
    assert_equal(3, swarm.agent_names.size)
    assert_includes(swarm.agent_names, :architect)
    assert_includes(swarm.agent_names, :backend)
    assert_includes(swarm.agent_names, :frontend)
  end

  def test_load_ruby_dsl_with_hooks
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      SwarmSDK.build do
        name "Hooked Team"
        lead :backend

        agent :backend do
          model "gpt-4"
          description "Backend developer"
          system_prompt "You build APIs"
          tools :Read, :Write

          hook :pre_tool_use, matcher: "Write" do |ctx|
            # Validation hook
          end
        end
      end
    RUBY

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Hooked Team", swarm.name)
  end

  def test_raises_error_for_missing_file
    config_path = File.join(@tmpdir, "missing.yml")

    error = assert_raises(SwarmCLI::ConfigurationError) do
      SwarmCLI::ConfigLoader.load(config_path)
    end

    assert_match(/not found/, error.message)
  end

  def test_raises_error_for_unsupported_extension
    config_path = File.join(@tmpdir, "config.txt")
    File.write(config_path, "some content")

    error = assert_raises(SwarmCLI::ConfigurationError) do
      SwarmCLI::ConfigLoader.load(config_path)
    end

    assert_match(/Unsupported configuration file format/, error.message)
    assert_match(/\.txt/, error.message)
  end

  def test_raises_error_for_invalid_yaml
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, <<~YAML)
      version: 2
      swarm:
        name: "Invalid Team"
        # Missing lead and agents
    YAML

    error = assert_raises(SwarmCLI::ConfigurationError) do
      SwarmCLI::ConfigLoader.load(config_path)
    end

    assert_match(/Configuration error/, error.message)
  end

  def test_raises_error_for_ruby_dsl_returning_wrong_type
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      # Returns a string instead of a Swarm
      "Not a swarm"
    RUBY

    error = assert_raises(SwarmCLI::ConfigurationError) do
      SwarmCLI::ConfigLoader.load(config_path)
    end

    assert_match(/must return a SwarmSDK::Swarm or SwarmSDK::Workflow instance/, error.message)
    assert_match(/Got: String/, error.message)
  end

  def test_raises_error_for_ruby_syntax_error
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      SwarmSDK.build do
        name "Test"
        # Syntax error - missing end
    RUBY

    error = assert_raises(SwarmCLI::ConfigurationError) do
      SwarmCLI::ConfigLoader.load(config_path)
    end

    assert_match(/Syntax error/, error.message)
  end

  def test_raises_error_for_ruby_runtime_error
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      SwarmSDK.build do
        name "Test"
        # Missing required lead field - will raise error
        agent :backend do
          model "gpt-4"
        end
      end
    RUBY

    error = assert_raises(SwarmCLI::ConfigurationError) do
      SwarmCLI::ConfigLoader.load(config_path)
    end

    assert_match(/Configuration error/, error.message)
  end

  def test_load_accepts_pathname
    config_path = Pathname.new(File.join(@tmpdir, "config.yml"))
    File.write(config_path, <<~YAML)
      version: 2
      swarm:
        name: "Pathname Test"
        lead: backend
        agents:
          backend:
            description: "Backend developer"
            model: gpt-4
    YAML

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Pathname Test", swarm.name)
  end

  def test_load_expands_relative_paths
    # Create config in tmpdir
    config_path = "config.yml"
    full_path = File.join(@tmpdir, config_path)
    File.write(full_path, <<~YAML)
      version: 2
      swarm:
        name: "Relative Path Test"
        lead: backend
        agents:
          backend:
            description: "Backend developer"
            model: gpt-4
    YAML

    # Change to tmpdir and use relative path
    Dir.chdir(@tmpdir) do
      swarm = SwarmCLI::ConfigLoader.load(config_path)

      assert_instance_of(SwarmSDK::Swarm, swarm)
      assert_equal("Relative Path Test", swarm.name)
    end
  end

  def test_ruby_dsl_has_access_to_swarm_sdk
    config_path = File.join(@tmpdir, "config.rb")
    File.write(config_path, <<~RUBY)
      # Verify SwarmSDK is available in the eval context
      raise "SwarmSDK not available" unless defined?(SwarmSDK)

      SwarmSDK.build do
        name "Context Test"
        lead :backend

        agent :backend do
          model "gpt-4"
          description "Backend developer"
          system_prompt "You build APIs"
        end
      end
    RUBY

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Context Test", swarm.name)
  end

  def test_case_insensitive_extension_matching
    # Test uppercase extensions
    config_path = File.join(@tmpdir, "config.YML")
    File.write(config_path, <<~YAML)
      version: 2
      swarm:
        name: "Uppercase Ext"
        lead: backend
        agents:
          backend:
            description: "Backend developer"
            model: gpt-4
    YAML

    swarm = SwarmCLI::ConfigLoader.load(config_path)

    assert_instance_of(SwarmSDK::Swarm, swarm)
    assert_equal("Uppercase Ext", swarm.name)
  end
end
