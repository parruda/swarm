# frozen_string_literal: true

module SwarmSDK
  # Centralized configuration for SwarmSDK
  #
  # Config provides a single entry point for all SwarmSDK configuration,
  # including API keys (proxied to RubyLLM), defaults override, and
  # WebFetch settings.
  #
  # ## Priority Order
  #
  # Configuration values are resolved in this order:
  # 1. Explicit value (set via SwarmSDK.configure)
  # 2. Environment variable
  # 3. Module default (from SwarmSDK::Defaults)
  #
  # ## API Key Proxying
  #
  # API keys are automatically proxied to RubyLLM.config when set,
  # ensuring RubyLLM always has the correct credentials.
  #
  # @example Basic configuration
  #   SwarmSDK.configure do |config|
  #     config.openai_api_key = "sk-..."
  #     config.default_model = "claude-sonnet-4"
  #     config.agent_request_timeout = 600
  #   end
  #
  # @example Testing setup
  #   def setup
  #     SwarmSDK.reset_config!
  #   end
  class Config
    # API keys that proxy to RubyLLM.config
    # Maps SwarmSDK config key => [RubyLLM config key, ENV variable]
    API_KEY_MAPPINGS = {
      openai_api_key: [:openai_api_key, "OPENAI_API_KEY"],
      openai_api_base: [:openai_api_base, "OPENAI_API_BASE"],
      openai_organization_id: [:openai_organization_id, "OPENAI_ORG_ID"],
      openai_project_id: [:openai_project_id, "OPENAI_PROJECT_ID"],
      anthropic_api_key: [:anthropic_api_key, "ANTHROPIC_API_KEY"],
      gemini_api_key: [:gemini_api_key, "GEMINI_API_KEY"],
      gemini_api_base: [:gemini_api_base, "GEMINI_API_BASE"],
      vertexai_project_id: [:vertexai_project_id, "GOOGLE_CLOUD_PROJECT"],
      vertexai_location: [:vertexai_location, "GOOGLE_CLOUD_LOCATION"],
      deepseek_api_key: [:deepseek_api_key, "DEEPSEEK_API_KEY"],
      mistral_api_key: [:mistral_api_key, "MISTRAL_API_KEY"],
      perplexity_api_key: [:perplexity_api_key, "PERPLEXITY_API_KEY"],
      openrouter_api_key: [:openrouter_api_key, "OPENROUTER_API_KEY"],
      bedrock_api_key: [:bedrock_api_key, "AWS_ACCESS_KEY_ID"],
      bedrock_secret_key: [:bedrock_secret_key, "AWS_SECRET_ACCESS_KEY"],
      bedrock_region: [:bedrock_region, "AWS_REGION"],
      bedrock_session_token: [:bedrock_session_token, "AWS_SESSION_TOKEN"],
      ollama_api_base: [:ollama_api_base, "OLLAMA_API_BASE"],
      gpustack_api_base: [:gpustack_api_base, "GPUSTACK_API_BASE"],
      gpustack_api_key: [:gpustack_api_key, "GPUSTACK_API_KEY"],
    }.freeze

    # RubyLLM connection settings that proxy to RubyLLM.config
    # Maps SwarmSDK config key => [RubyLLM config key, ENV variable, default value]
    RUBYLLM_CONNECTION_MAPPINGS = {
      llm_request_timeout: [:request_timeout, "SWARM_SDK_LLM_REQUEST_TIMEOUT", 300],
      llm_read_timeout: [:read_timeout, "SWARM_SDK_LLM_READ_TIMEOUT", nil], # nil = use request_timeout
      llm_open_timeout: [:open_timeout, "SWARM_SDK_LLM_OPEN_TIMEOUT", 30],
      llm_write_timeout: [:write_timeout, "SWARM_SDK_LLM_WRITE_TIMEOUT", 30],
    }.freeze

    # SwarmSDK defaults that can be overridden
    # Maps config key => [ENV variable, default proc]
    DEFAULTS_MAPPINGS = {
      default_model: ["SWARM_SDK_DEFAULT_MODEL", -> { Defaults::Agent::MODEL }],
      default_provider: ["SWARM_SDK_DEFAULT_PROVIDER", -> { Defaults::Agent::PROVIDER }],
      agent_request_timeout: ["SWARM_SDK_AGENT_REQUEST_TIMEOUT", -> { Defaults::Timeouts::AGENT_REQUEST_SECONDS }],
      bash_command_timeout: ["SWARM_SDK_BASH_COMMAND_TIMEOUT", -> { Defaults::Timeouts::BASH_COMMAND_MS }],
      bash_command_max_timeout: ["SWARM_SDK_BASH_COMMAND_MAX_TIMEOUT", -> { Defaults::Timeouts::BASH_COMMAND_MAX_MS }],
      web_fetch_timeout: ["SWARM_SDK_WEB_FETCH_TIMEOUT", -> { Defaults::Timeouts::WEB_FETCH_SECONDS }],
      hook_shell_timeout: ["SWARM_SDK_HOOK_SHELL_TIMEOUT", -> { Defaults::Timeouts::HOOK_SHELL_SECONDS }],
      transformer_command_timeout: ["SWARM_SDK_TRANSFORMER_COMMAND_TIMEOUT", -> { Defaults::Timeouts::TRANSFORMER_COMMAND_SECONDS }],
      global_concurrency_limit: ["SWARM_SDK_GLOBAL_CONCURRENCY_LIMIT", -> { Defaults::Concurrency::GLOBAL_LIMIT }],
      local_concurrency_limit: ["SWARM_SDK_LOCAL_CONCURRENCY_LIMIT", -> { Defaults::Concurrency::LOCAL_LIMIT }],
      output_character_limit: ["SWARM_SDK_OUTPUT_CHARACTER_LIMIT", -> { Defaults::Limits::OUTPUT_CHARACTERS }],
      read_line_limit: ["SWARM_SDK_READ_LINE_LIMIT", -> { Defaults::Limits::READ_LINES }],
      line_character_limit: ["SWARM_SDK_LINE_CHARACTER_LIMIT", -> { Defaults::Limits::LINE_CHARACTERS }],
      web_fetch_character_limit: ["SWARM_SDK_WEB_FETCH_CHARACTER_LIMIT", -> { Defaults::Limits::WEB_FETCH_CHARACTERS }],
      glob_result_limit: ["SWARM_SDK_GLOB_RESULT_LIMIT", -> { Defaults::Limits::GLOB_RESULTS }],
      scratchpad_entry_size_limit: ["SWARM_SDK_SCRATCHPAD_ENTRY_SIZE_LIMIT", -> { Defaults::Storage::ENTRY_SIZE_BYTES }],
      scratchpad_total_size_limit: ["SWARM_SDK_SCRATCHPAD_TOTAL_SIZE_LIMIT", -> { Defaults::Storage::TOTAL_SIZE_BYTES }],
      context_compression_threshold: ["SWARM_SDK_CONTEXT_COMPRESSION_THRESHOLD", -> { Defaults::Context::COMPRESSION_THRESHOLD_PERCENT }],
      todowrite_reminder_interval: ["SWARM_SDK_TODOWRITE_REMINDER_INTERVAL", -> { Defaults::Context::TODOWRITE_REMINDER_INTERVAL }],
      chars_per_token_prose: ["SWARM_SDK_CHARS_PER_TOKEN_PROSE", -> { Defaults::TokenEstimation::CHARS_PER_TOKEN_PROSE }],
      chars_per_token_code: ["SWARM_SDK_CHARS_PER_TOKEN_CODE", -> { Defaults::TokenEstimation::CHARS_PER_TOKEN_CODE }],
      mcp_log_level: ["SWARM_SDK_MCP_LOG_LEVEL", -> { Defaults::Logging::MCP_LOG_LEVEL }],
      default_execution_timeout: ["SWARM_SDK_DEFAULT_EXECUTION_TIMEOUT", -> { Defaults::Timeouts::EXECUTION_TIMEOUT_SECONDS }],
      default_turn_timeout: ["SWARM_SDK_DEFAULT_TURN_TIMEOUT", -> { Defaults::Timeouts::TURN_TIMEOUT_SECONDS }],
      mcp_request_timeout: ["SWARM_SDK_MCP_REQUEST_TIMEOUT", -> { Defaults::Timeouts::MCP_REQUEST_SECONDS }],
    }.freeze

    # WebFetch and control settings
    # Maps config key => [ENV variable, default value]
    SETTINGS_MAPPINGS = {
      webfetch_provider: ["SWARM_SDK_WEBFETCH_PROVIDER", nil],
      webfetch_model: ["SWARM_SDK_WEBFETCH_MODEL", nil],
      webfetch_base_url: ["SWARM_SDK_WEBFETCH_BASE_URL", nil],
      webfetch_max_tokens: ["SWARM_SDK_WEBFETCH_MAX_TOKENS", 4096],
      allow_filesystem_tools: ["SWARM_SDK_ALLOW_FILESYSTEM_TOOLS", true],
      env_interpolation: ["SWARM_SDK_ENV_INTERPOLATION", true],
      streaming: ["SWARM_SDK_STREAMING", true],
    }.freeze

    class << self
      # Get the singleton Config instance
      #
      # @return [Config] The singleton instance
      def instance
        @instance ||= new
      end

      # Reset the Config instance
      #
      # Clears all configuration including explicit values and cached ENV values.
      # Use in tests to ensure clean state.
      #
      # @return [void]
      def reset!
        @instance = nil
      end
    end

    # Initialize a new Config instance
    #
    # @note Use Config.instance instead of new for the singleton pattern
    def initialize
      @explicit_values = {}
      @env_values = {}
      @env_loaded = false
      @env_mutex = Mutex.new
    end

    # ========== API Key Accessors (with RubyLLM proxying) ==========

    # @!method openai_api_key
    #   Get the OpenAI API key
    #   @return [String, nil] The API key
    #
    # @!method openai_api_key=(value)
    #   Set the OpenAI API key (proxied to RubyLLM)
    #   @param value [String] The API key

    API_KEY_MAPPINGS.each_key do |config_key|
      ruby_llm_key, _ = API_KEY_MAPPINGS[config_key]

      # Getter
      define_method(config_key) do
        ensure_env_loaded!
        @explicit_values[config_key] || @env_values[config_key]
      end

      # Setter with RubyLLM proxying
      define_method("#{config_key}=") do |value|
        @explicit_values[config_key] = value
        RubyLLM.config.public_send("#{ruby_llm_key}=", value) if value
      end
    end

    # ========== RubyLLM Connection Accessors (with RubyLLM proxying) ==========

    # @!method llm_request_timeout
    #   Get the LLM request timeout (seconds)
    #   @return [Integer] The timeout (default: 300)
    #
    # @!method llm_read_timeout
    #   Get the LLM read timeout (seconds) - time to wait between chunks
    #   @return [Integer, nil] The timeout (nil = use request_timeout)
    #
    # @!method llm_open_timeout
    #   Get the LLM connection open timeout (seconds)
    #   @return [Integer] The timeout (default: 30)
    #
    # @!method llm_write_timeout
    #   Get the LLM write timeout (seconds)
    #   @return [Integer] The timeout (default: 30)

    RUBYLLM_CONNECTION_MAPPINGS.each_key do |config_key|
      ruby_llm_key, _env_key, default_value = RUBYLLM_CONNECTION_MAPPINGS[config_key]

      # Getter with default fallback
      define_method(config_key) do
        ensure_env_loaded!
        if @explicit_values.key?(config_key)
          @explicit_values[config_key]
        elsif @env_values.key?(config_key)
          @env_values[config_key]
        else
          default_value
        end
      end

      # Setter with RubyLLM proxying
      define_method("#{config_key}=") do |value|
        @explicit_values[config_key] = value
        RubyLLM.config.public_send("#{ruby_llm_key}=", value)
      end
    end

    # ========== Defaults Accessors (with module constant fallback) ==========

    # @!method default_model
    #   Get the default model
    #   @return [String] The default model (falls back to Defaults::Agent::MODEL)
    #
    # @!method default_model=(value)
    #   Set the default model
    #   @param value [String] The default model

    DEFAULTS_MAPPINGS.each_key do |config_key|
      _env_key, default_proc = DEFAULTS_MAPPINGS[config_key]

      # Getter with default fallback
      define_method(config_key) do
        ensure_env_loaded!
        @explicit_values[config_key] || @env_values[config_key] || default_proc.call
      end

      # Setter
      define_method("#{config_key}=") do |value|
        @explicit_values[config_key] = value
      end
    end

    # ========== Settings Accessors (WebFetch and control) ==========

    # @!method webfetch_provider
    #   Get the WebFetch LLM provider
    #   @return [String, nil] The provider
    #
    # @!method allow_filesystem_tools
    #   Get whether filesystem tools are allowed
    #   @return [Boolean] true if allowed

    SETTINGS_MAPPINGS.each_key do |config_key|
      _env_key, default_value = SETTINGS_MAPPINGS[config_key]

      # Getter with default fallback
      define_method(config_key) do
        ensure_env_loaded!
        if @explicit_values.key?(config_key)
          @explicit_values[config_key]
        elsif @env_values.key?(config_key)
          @env_values[config_key]
        else
          default_value
        end
      end

      # Setter
      define_method("#{config_key}=") do |value|
        @explicit_values[config_key] = value
      end
    end

    # ========== Convenience Methods ==========

    # Check if WebFetch LLM processing is enabled
    #
    # WebFetch uses LLM processing when both provider and model are configured.
    #
    # @return [Boolean] true if WebFetch LLM is configured
    def webfetch_llm_enabled?
      !webfetch_provider.nil? && !webfetch_model.nil?
    end

    private

    # Ensure ENV values are loaded (lazy loading with double-check locking)
    #
    # Thread-safe lazy loading of ENV values. Only loads once per Config instance.
    #
    # @return [void]
    def ensure_env_loaded!
      return if @env_loaded

      @env_mutex.synchronize do
        return if @env_loaded

        load_env_values!
        @env_loaded = true
      end
    end

    # Load environment variable values
    #
    # Loads API keys (with RubyLLM proxying), defaults, and settings from ENV.
    # Only loads values that haven't been explicitly set.
    #
    # @return [void]
    def load_env_values!
      # Load API keys and proxy to RubyLLM
      API_KEY_MAPPINGS.each do |config_key, (ruby_llm_key, env_key)|
        next if @explicit_values.key?(config_key)
        next unless ENV.key?(env_key)

        value = ENV[env_key]
        @env_values[config_key] = value

        # Proxy to RubyLLM
        RubyLLM.config.public_send("#{ruby_llm_key}=", value)
      end

      # Load RubyLLM connection settings and proxy to RubyLLM
      RUBYLLM_CONNECTION_MAPPINGS.each do |config_key, (ruby_llm_key, env_key, _default)|
        next if @explicit_values.key?(config_key)
        next unless ENV.key?(env_key)

        value = parse_env_value(ENV[env_key], config_key)
        @env_values[config_key] = value

        # Proxy to RubyLLM
        RubyLLM.config.public_send("#{ruby_llm_key}=", value)
      end

      # Load defaults (no RubyLLM proxy)
      DEFAULTS_MAPPINGS.each do |config_key, (env_key, _default_proc)|
        next if @explicit_values.key?(config_key)
        next unless ENV.key?(env_key)

        @env_values[config_key] = parse_env_value(ENV[env_key], config_key)
      end

      # Load settings (no RubyLLM proxy)
      SETTINGS_MAPPINGS.each do |config_key, (env_key, _default_value)|
        next if @explicit_values.key?(config_key)
        next unless ENV.key?(env_key)

        @env_values[config_key] = parse_env_value(ENV[env_key], config_key)
      end
    end

    # Parse environment variable value to appropriate type
    #
    # Converts string ENV values to integers, floats, or booleans based on
    # the configuration key pattern.
    #
    # @param value [String] The ENV value string
    # @param key [Symbol] The configuration key
    # @return [Integer, Float, Boolean, String] The parsed value
    def parse_env_value(value, key)
      case key
      when :allow_filesystem_tools, :env_interpolation, :streaming
        # Convert string to boolean
        case value.to_s.downcase
        when "true", "yes", "1", "on", "enabled"
          true
        when "false", "no", "0", "off", "disabled"
          false
        else
          true # Default to true if unrecognized
        end
      when /_timeout$/, /_limit$/, /_interval$/, /_threshold$/, :mcp_log_level, :webfetch_max_tokens
        value.to_i
      when /^chars_per_token/
        value.to_f
      else
        value
      end
    end
  end
end
