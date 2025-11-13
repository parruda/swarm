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
    # Settings for SwarmSDK (global configuration)
    attr_accessor :settings

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

    # Configure SwarmSDK global settings
    def configure
      self.settings ||= Settings.new
      yield(settings)
    end

    # Reset settings to defaults
    def reset_settings!
      self.settings = Settings.new
    end

    # Alias for backward compatibility
    alias_method :configuration, :settings
    alias_method :reset_configuration!, :reset_settings!

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

  # Settings class for SwarmSDK global settings (not to be confused with Configuration for YAML loading)
  class Settings
    # WebFetch tool LLM processing configuration
    attr_accessor :webfetch_provider, :webfetch_model, :webfetch_base_url, :webfetch_max_tokens

    # Filesystem tools control
    attr_accessor :allow_filesystem_tools

    def initialize
      @webfetch_provider = nil
      @webfetch_model = nil
      @webfetch_base_url = nil
      @webfetch_max_tokens = 4096
      @allow_filesystem_tools = parse_env_bool("SWARM_SDK_ALLOW_FILESYSTEM_TOOLS", default: true)
    end

    # Check if WebFetch LLM processing is enabled
    def webfetch_llm_enabled?
      !@webfetch_provider.nil? && !@webfetch_model.nil?
    end

    private

    def parse_env_bool(key, default:)
      return default unless ENV.key?(key)

      value = ENV[key].to_s.downcase
      return true if ["true", "yes", "1", "on", "enabled"].include?(value)
      return false if ["false", "no", "0", "off", "disabled"].include?(value)

      default
    end
  end

  # Initialize default settings
  self.settings = Settings.new
end

# Automatically configure RubyLLM from environment variables
# This makes SwarmSDK "just work" when users set standard ENV variables
RubyLLM.configure do |config|
  # Only set if config not already set (||= handles nil ENV values gracefully)

  # OpenAI
  config.openai_api_key ||= ENV["OPENAI_API_KEY"]
  config.openai_api_base ||= ENV["OPENAI_API_BASE"]
  config.openai_organization_id ||= ENV["OPENAI_ORG_ID"]
  config.openai_project_id ||= ENV["OPENAI_PROJECT_ID"]

  # Anthropic
  config.anthropic_api_key ||= ENV["ANTHROPIC_API_KEY"]

  # Google Gemini
  config.gemini_api_key ||= ENV["GEMINI_API_KEY"]

  # Google Vertex AI (note: vertexai, not vertex_ai)
  config.vertexai_project_id ||= ENV["GOOGLE_CLOUD_PROJECT"] || ENV["VERTEXAI_PROJECT_ID"]
  config.vertexai_location ||= ENV["GOOGLE_CLOUD_LOCATION"] || ENV["VERTEXAI_LOCATION"]

  # DeepSeek
  config.deepseek_api_key ||= ENV["DEEPSEEK_API_KEY"]

  # Mistral
  config.mistral_api_key ||= ENV["MISTRAL_API_KEY"]

  # Perplexity
  config.perplexity_api_key ||= ENV["PERPLEXITY_API_KEY"]

  # OpenRouter
  config.openrouter_api_key ||= ENV["OPENROUTER_API_KEY"]

  # AWS Bedrock
  config.bedrock_api_key ||= ENV["AWS_ACCESS_KEY_ID"]
  config.bedrock_secret_key ||= ENV["AWS_SECRET_ACCESS_KEY"]
  config.bedrock_region ||= ENV["AWS_REGION"]
  config.bedrock_session_token ||= ENV["AWS_SESSION_TOKEN"]

  # Ollama (local)
  config.ollama_api_base ||= ENV["OLLAMA_API_BASE"]

  # GPUStack (local)
  config.gpustack_api_base ||= ENV["GPUSTACK_API_BASE"]
  config.gpustack_api_key ||= ENV["GPUSTACK_API_KEY"]
end
