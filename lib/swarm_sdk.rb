# frozen_string_literal: true

require "bundler"
require "digest"
require "English"
require "erb"
require "fileutils"
require "json"
require "logger"
require "pathname"
require "securerandom"
require "set"
require "yaml"

require "async"
require "async/semaphore"
require "ruby_llm"
require "ruby_llm/mcp"

# Patch ruby_llm-mcp's Zeitwerk loader to ignore railtie.rb when Rails is not present
# This prevents NameError when eager loading outside of Rails applications
# Can be removed once https://github.com/parruda/ruby_llm-mcp/issues/XXX is fixed
unless defined?(Rails)
  require "zeitwerk"
  mcp_loader = nil
  Zeitwerk::Registry.loaders.each { |l| mcp_loader = l if l.tag == "RubyLLM-mcp" }
  if mcp_loader
    mcp_gem_dir = Gem.loaded_specs["ruby_llm-mcp"]&.gem_dir
    if mcp_gem_dir
      railtie_path = File.join(mcp_gem_dir, "lib", "ruby_llm", "mcp", "railtie.rb")
      mcp_loader.ignore(railtie_path)
    end
  end
end

# Configure Faraday to use async-http adapter by default
# This ensures HTTP requests are fiber-aware and don't block the Async scheduler
# when SwarmSDK executes LLM requests within Async/Sync blocks
require "async/http/faraday/default"

require_relative "swarm_sdk/version"

require "zeitwerk"
loader = Zeitwerk::Loader.new
loader.tag = File.basename(__FILE__, ".rb")
loader.push_dir("#{__dir__}/swarm_sdk", namespace: SwarmSDK)
loader.inflector = Zeitwerk::GemInflector.new(__FILE__)
loader.inflector.inflect(
  "cli" => "CLI",
  "llm_instrumentation_middleware" => "LLMInstrumentationMiddleware",
  "mcp" => "MCP",
  "openai_with_responses" => "OpenAIWithResponses",
)
loader.setup

module SwarmSDK
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AgentNotFoundError < Error; end
  class CircularDependencyError < Error; end
  class ToolExecutionError < Error; end
  class LLMError < Error; end
  class StateError < Error; end

  class << self
    # Get the global configuration instance
    #
    # @return [Config] The singleton Config instance
    def config
      Config.instance
    end

    # Configure SwarmSDK global settings
    #
    # @yield [Config] The configuration instance
    # @return [Config] The configuration instance
    #
    # @example
    #   SwarmSDK.configure do |config|
    #     config.openai_api_key = "sk-..."
    #     config.default_model = "claude-sonnet-4"
    #   end
    def configure
      yield(config) if block_given?
      config
    end

    # Reset configuration to defaults
    #
    # Clears all configuration including explicit values and cached ENV values.
    # Use in tests to ensure clean state.
    #
    # @return [void]
    def reset_config!
      Config.reset!
    end

    # Register a global agent definition
    #
    # Declares an agent configuration that can be referenced by name in any
    # swarm definition. This allows defining agents in separate files and
    # composing them into swarms without duplication.
    #
    # The registered block uses the Agent::Builder DSL and is executed when
    # the agent is referenced in a swarm definition.
    #
    # @param name [Symbol, String] Agent name (will be symbolized)
    # @yield Agent configuration block using Agent::Builder DSL
    # @return [void]
    # @raise [ArgumentError] If no block is provided
    #
    # @example Register agent in separate file
    #   # agents/backend.rb
    #   SwarmSDK.agent :backend do
    #     model "claude-sonnet-4"
    #     description "Backend API developer"
    #     system_prompt "You build REST APIs"
    #     tools :Read, :Edit, :Bash
    #     delegates_to :database
    #   end
    #
    # @example Reference in swarm definition
    #   # swarm.rb
    #   require_relative "agents/backend"
    #
    #   SwarmSDK.build do
    #     name "Dev Team"
    #     lead :backend
    #
    #     agent :backend  # Pulls from registry
    #   end
    #
    # @example Extend registered agent with overrides
    #   SwarmSDK.build do
    #     name "Extended Team"
    #     lead :backend
    #
    #     agent :backend do
    #       # Registry config applied first, then this block
    #       tools :CustomTool    # Adds to existing tools
    #       delegates_to :cache  # Adds delegation target
    #     end
    #   end
    #
    # @see AgentRegistry
    def agent(name, &block)
      AgentRegistry.register(name, &block)
    end

    # Clear the global agent registry
    #
    # Removes all registered agent definitions. Primarily useful for testing
    # to ensure clean state between tests.
    #
    # @return [void]
    #
    # @example In test teardown
    #   def teardown
    #     SwarmSDK.clear_agent_registry!
    #   end
    def clear_agent_registry!
      AgentRegistry.clear
    end

    # Main entry point for DSL - builds simple multi-agent swarms
    #
    # @return [Swarm] Always returns a Swarm instance
    def build(allow_filesystem_tools: nil, &block)
      Swarm::Builder.build(allow_filesystem_tools: allow_filesystem_tools, &block)
    end

    # Entry point for building multi-stage workflows
    #
    # @return [Workflow] Always returns a Workflow instance
    def workflow(allow_filesystem_tools: nil, &block)
      Workflow::Builder.build(allow_filesystem_tools: allow_filesystem_tools, &block)
    end

    # Validate YAML configuration without creating a swarm
    #
    # Performs comprehensive validation of YAML configuration including:
    # - YAML syntax
    # - Required fields (version, swarm name, lead, agents)
    # - Agent configurations (description, directory existence)
    # - Circular dependencies
    # - File references (agent_file paths)
    # - Hook configurations
    #
    # @param yaml_content [String] YAML configuration content
    # @param base_dir [String, Pathname] Base directory for resolving agent file paths (default: Dir.pwd)
    # @return [Array<Hash>] Array of error hashes (empty if valid)
    #
    # @example Validate YAML string
    #   errors = SwarmSDK.validate(yaml_content)
    #   if errors.empty?
    #     puts "Configuration is valid!"
    #   else
    #     errors.each do |error|
    #       puts "#{error[:field]}: #{error[:message]}"
    #     end
    #   end
    #
    # @example Error hash structure
    #   {
    #     type: :missing_field,           # Error type
    #     field: "swarm.agents.backend.description",  # JSON-style path to field
    #     message: "Agent 'backend' missing required 'description' field",
    #     agent: "backend"                # Optional, present if error is agent-specific
    #   }
    def validate(yaml_content, base_dir: Dir.pwd)
      errors = []

      begin
        config = Configuration.new(yaml_content, base_dir: base_dir)
        config.load_and_validate

        # Build swarm to trigger DSL validation
        # This catches errors from Agent::Definition, Builder, etc.
        config.to_swarm
      rescue ConfigurationError, CircularDependencyError => e
        errors << parse_configuration_error(e)
      rescue StandardError => e
        errors << {
          type: :unknown_error,
          field: nil,
          message: e.message,
        }
      end

      errors
    end

    # Validate YAML configuration file
    #
    # Convenience method that reads the file and validates the content.
    #
    # @param path [String, Pathname] Path to YAML configuration file
    # @return [Array<Hash>] Array of error hashes (empty if valid)
    #
    # @example
    #   errors = SwarmSDK.validate_file("config.yml")
    #   if errors.empty?
    #     puts "Valid configuration!"
    #     swarm = SwarmSDK.load_file("config.yml")
    #   else
    #     errors.each { |e| puts "Error: #{e[:message]}" }
    #   end
    def validate_file(path)
      path = Pathname.new(path).expand_path

      unless path.exist?
        return [{
          type: :file_not_found,
          field: nil,
          message: "Configuration file not found: #{path}",
        }]
      end

      yaml_content = File.read(path)
      base_dir = path.dirname

      validate(yaml_content, base_dir: base_dir)
    rescue StandardError => e
      [{
        type: :file_read_error,
        field: nil,
        message: "Error reading file: #{e.message}",
      }]
    end

    # Load swarm from YAML string
    #
    # This is the primary programmatic API for loading YAML configurations.
    # For file-based loading, use SwarmSDK.load_file for convenience.
    #
    # @param yaml_content [String] YAML configuration content
    # @param base_dir [String, Pathname] Base directory for resolving agent file paths (default: Dir.pwd)
    # @return [Swarm, Workflow] Configured swarm or workflow instance
    # @raise [ConfigurationError] If YAML is invalid or configuration is incorrect
    #
    # @example Load from YAML string
    #   yaml = <<~YAML
    #     version: 2
    #     swarm:
    #       name: "Dev Team"
    #       lead: backend
    #       agents:
    #         backend:
    #           description: "Backend developer"
    #           model: "gpt-4"
    #           agent_file: "agents/backend.md"  # Resolved relative to base_dir
    #   YAML
    #
    #   swarm = SwarmSDK.load(yaml, base_dir: "/path/to/project")
    #   result = swarm.execute("Build authentication")
    #
    # @example Load with default base_dir (Dir.pwd)
    #   yaml = File.read("config.yml")
    #   swarm = SwarmSDK.load(yaml)  # base_dir defaults to Dir.pwd
    def load(yaml_content, base_dir: Dir.pwd, allow_filesystem_tools: nil)
      config = Configuration.new(yaml_content, base_dir: base_dir)
      config.load_and_validate
      swarm = config.to_swarm(allow_filesystem_tools: allow_filesystem_tools)

      # Apply hooks if any are configured (YAML-only feature)
      if hooks_configured?(config)
        Hooks::Adapter.apply_hooks(swarm, config)
      end

      # Store config reference for agent hooks (applied during initialize_agents)
      swarm.config_for_hooks = config

      swarm
    end

    # Load swarm from YAML file (convenience method)
    #
    # Reads the YAML file and uses the file's directory as the base directory
    # for resolving agent file paths. This is the recommended method for
    # loading swarms from configuration files.
    #
    # @param path [String, Pathname] Path to YAML configuration file
    # @return [Swarm, Workflow] Configured swarm or workflow instance
    # @raise [ConfigurationError] If file not found or configuration invalid
    #
    # @example
    #   swarm = SwarmSDK.load_file("config.yml")
    #   result = swarm.execute("Build authentication")
    #
    # @example With absolute path
    #   swarm = SwarmSDK.load_file("/absolute/path/config.yml")
    def load_file(path, allow_filesystem_tools: nil)
      config = Configuration.load_file(path)
      swarm = config.to_swarm(allow_filesystem_tools: allow_filesystem_tools)

      # Apply hooks if any are configured (YAML-only feature)
      if hooks_configured?(config)
        Hooks::Adapter.apply_hooks(swarm, config)
      end

      # Store config reference for agent hooks (applied during initialize_agents)
      swarm.config_for_hooks = config

      swarm
    end

    private

    # Check if hooks are configured in the configuration
    #
    # @param config [Configuration] Configuration instance
    # @return [Boolean] true if any hooks are configured
    def hooks_configured?(config)
      config.swarm_hooks.any? ||
        config.all_agents_hooks.any? ||
        config.agents.any? { |_, agent_config| agent_config[:hooks]&.any? }
    end

    # Parse configuration error and extract structured information
    #
    # Attempts to extract field path and agent name from error messages.
    # Returns a structured error hash with type, field, message, and optional agent.
    #
    # @param error [StandardError] The caught error
    # @return [Hash] Structured error hash
    def parse_configuration_error(error)
      message = error.message
      error_hash = { message: message }

      # Detect error type and extract field information
      case message
      # YAML syntax errors
      when /Invalid YAML syntax/i
        error_hash.merge!(
          type: :syntax_error,
          field: nil,
        )

      # Missing version field
      when /Missing 'version' field/i
        error_hash.merge!(
          type: :missing_field,
          field: "version",
        )

      # Invalid version
      when /SwarmSDK requires version: (\d+)/i
        error_hash.merge!(
          type: :invalid_value,
          field: "version",
        )

      # Missing swarm fields
      when /Missing '(\w+)' field in swarm configuration/i
        field_name = Regexp.last_match(1)
        error_hash.merge!(
          type: :missing_field,
          field: "swarm.#{field_name}",
        )

      # Agent missing required field
      when /Agent '([^']+)' missing required '([^']+)' field/i
        agent_name = Regexp.last_match(1)
        field_name = Regexp.last_match(2)
        error_hash.merge!(
          type: :missing_field,
          field: "swarm.agents.#{agent_name}.#{field_name}",
          agent: agent_name,
        )

      # Directory does not exist
      when /Directory '([^']+)' for agent '([^']+)' does not exist/i
        agent_name = Regexp.last_match(2)
        error_hash.merge!(
          type: :directory_not_found,
          field: "swarm.agents.#{agent_name}.directory",
          agent: agent_name,
        )

      # Error loading agent from file (must come before "Agent file not found")
      when /Error loading agent '([^']+)' from file/i
        agent_name = Regexp.last_match(1)
        error_hash.merge!(
          type: :file_load_error,
          field: "swarm.agents.#{agent_name}.agent_file",
          agent: agent_name,
        )

      # Agent file not found
      when /Agent file not found: (.+)/i
        # Try to extract agent name from the error context if available
        error_hash.merge!(
          type: :file_not_found,
          field: nil, # We don't know which agent without more context
        )

      # Lead agent not found
      when /Lead agent '([^']+)' not found in agents/i
        error_hash.merge!(
          type: :invalid_reference,
          field: "swarm.lead",
        )

      # Unknown agent in connections (old format)
      when /Agent '([^']+)' has connection to unknown agent '([^']+)'/i
        agent_name = Regexp.last_match(1)
        error_hash.merge!(
          type: :invalid_reference,
          field: "swarm.agents.#{agent_name}.delegates_to",
          agent: agent_name,
        )

      # Unknown agent in connections (new format with composable swarms)
      when /Agent '([^']+)' delegates to unknown target '([^']+)'/i
        agent_name = Regexp.last_match(1)
        error_hash.merge!(
          type: :invalid_reference,
          field: "swarm.agents.#{agent_name}.delegates_to",
          agent: agent_name,
        )

      # Circular dependency
      when /Circular dependency detected/i
        error_hash.merge!(
          type: :circular_dependency,
          field: nil,
        )

      # Configuration file not found
      when /Configuration file not found/i
        error_hash.merge!(
          type: :file_not_found,
          field: nil,
        )

      # Invalid hook event
      when /Invalid hook event '([^']+)' for agent '([^']+)'/i
        agent_name = Regexp.last_match(2)
        error_hash.merge!(
          type: :invalid_value,
          field: "swarm.agents.#{agent_name}.hooks",
          agent: agent_name,
        )

      # api_version validation error
      when /Agent '([^']+)' has api_version set, but provider is/i
        agent_name = Regexp.last_match(1)
        error_hash.merge!(
          type: :invalid_value,
          field: "swarm.agents.#{agent_name}.api_version",
          agent: agent_name,
        )

      # api_version invalid value
      when /Agent '([^']+)' has invalid api_version/i
        agent_name = Regexp.last_match(1)
        error_hash.merge!(
          type: :invalid_value,
          field: "swarm.agents.#{agent_name}.api_version",
          agent: agent_name,
        )

      # No agents defined
      when /No agents defined/i
        error_hash.merge!(
          type: :missing_field,
          field: "swarm.agents",
        )

      # Default: unknown error
      else
        error_hash.merge!(
          type: :validation_error,
          field: nil,
        )
      end

      error_hash.compact
    end
  end
end
