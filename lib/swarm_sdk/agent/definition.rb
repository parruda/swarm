# frozen_string_literal: true

module SwarmSDK
  module Agent
    # Agent definition encapsulates agent configuration and builds system prompts
    #
    # This class is responsible for:
    # - Parsing and validating agent configuration
    # - Building the full system prompt (base + custom)
    # - Handling tool permissions
    # - Managing hooks (both DSL Ruby blocks and YAML shell commands)
    #
    # @example
    #   definition = Agent::Definition.new(:backend, {
    #     description: "Backend API developer",
    #     model: "gpt-5",
    #     tools: [:Read, :Write, :Bash],
    #     system_prompt: "You build APIs"
    #   })
    class Definition
      attr_reader :name,
        :description,
        :model,
        :context_window,
        :directory,
        :tools,
        :delegates_to,
        :system_prompt,
        :provider,
        :base_url,
        :api_version,
        :mcp_servers,
        :parameters,
        :headers,
        :timeout,
        :disable_default_tools,
        :coding_agent,
        :default_permissions,
        :agent_permissions,
        :assume_model_exists,
        :hooks,
        :plugin_configs,
        :shared_across_delegations

      attr_accessor :bypass_permissions, :max_concurrent_tools

      def initialize(name, config = {})
        @name = name.to_sym

        # Validate name doesn't contain '@' (reserved for delegation instances)
        if @name.to_s.include?("@")
          raise ConfigurationError,
            "Agent names cannot contain '@' character (reserved for delegation instance naming). " \
              "Agent: #{@name}"
        end

        # BREAKING CHANGE: Hard error for plural form
        if config[:directories]
          raise ConfigurationError,
            "The 'directories' (plural) configuration is no longer supported in SwarmSDK 1.0+.\n\n" \
              "Change 'directories:' to 'directory:' (singular).\n\n" \
              "If you need access to multiple directories, use permissions:\n\n  " \
              "directory: 'backend/'\n  " \
              "permissions do\n    " \
              "tool(:Read).allow_paths('../shared/**')\n  " \
              "end"
        end

        @description = config[:description]
        @model = config[:model] || Defaults::Agent::MODEL
        @provider = config[:provider] || Defaults::Agent::PROVIDER
        @base_url = config[:base_url]
        @api_version = config[:api_version]
        @context_window = config[:context_window] # Explicit context window override
        @parameters = config[:parameters] || {}
        @headers = Utils.stringify_keys(config[:headers] || {})
        @timeout = config[:timeout] || Defaults::Timeouts::AGENT_REQUEST_SECONDS
        @bypass_permissions = config[:bypass_permissions] || false
        @max_concurrent_tools = config[:max_concurrent_tools]
        # Always assume model exists - SwarmSDK validates models separately using models.json
        # This prevents RubyLLM from trying to validate models in its registry
        @assume_model_exists = true

        # disable_default_tools can be:
        # - nil/not set: include all default tools (default behavior)
        # - true: disable ALL default tools
        # - Array of symbols: disable specific tools (e.g., [:Think, :TodoWrite])
        @disable_default_tools = config[:disable_default_tools]

        # coding_agent defaults to false if not specified
        # When true, includes the base system prompt for coding tasks
        # When false, uses only the custom system prompt (no base prompt)
        @coding_agent = config.key?(:coding_agent) ? config[:coding_agent] : false

        # Parse directory first so it can be used in system prompt rendering
        @directory = parse_directory(config[:directory])

        # Extract plugin configurations (generic bucket for all plugin-specific keys)
        # This allows plugins to store their config without SDK knowing about them
        @plugin_configs = extract_plugin_configs(config)

        # Delegation isolation mode (default: false = isolated instances per delegation)
        @shared_across_delegations = config[:shared_across_delegations] || false

        # Build system prompt after directory and memory are set
        @system_prompt = build_full_system_prompt(config[:system_prompt])

        # Parse tools with permissions support
        @default_permissions = config[:default_permissions] || {}
        @agent_permissions = config[:permissions] || {}
        @tools = parse_tools_with_permissions(
          config[:tools],
          @default_permissions,
          @agent_permissions,
        )

        # Inject default write restrictions for security
        @tools = inject_default_write_permissions(@tools)

        @delegates_to = Array(config[:delegates_to] || []).map(&:to_sym).uniq
        @mcp_servers = Array(config[:mcp_servers] || [])

        # Parse hooks configuration
        # Handles both DSL (HookDefinition objects) and YAML (raw hash) formats
        @hooks = parse_hooks(config[:hooks])

        validate!
      end

      # Get plugin-specific configuration
      #
      # Plugins store their configuration in the generic plugin_configs hash.
      # This allows SDK to remain plugin-agnostic while plugins can store
      # arbitrary configuration.
      #
      # @param plugin_name [Symbol] Plugin name (e.g., :memory)
      # @return [Object, nil] Plugin configuration or nil if not present
      #
      # @example
      #   agent_definition.plugin_config(:memory)
      #   # => { directory: "tmp/memory", mode: :researcher }
      def plugin_config(plugin_name)
        @plugin_configs[plugin_name.to_sym] || @plugin_configs[plugin_name.to_s]
      end

      def to_h
        # Core SDK configuration (always serialized)
        base_config = {
          name: @name,
          description: @description,
          model: SwarmSDK::Models.resolve_alias(@model), # Resolve model aliases
          context_window: @context_window,
          directory: @directory,
          tools: @tools,
          delegates_to: @delegates_to,
          system_prompt: @system_prompt,
          provider: @provider,
          base_url: @base_url,
          api_version: @api_version,
          mcp_servers: @mcp_servers,
          parameters: @parameters,
          headers: @headers,
          timeout: @timeout,
          bypass_permissions: @bypass_permissions,
          disable_default_tools: @disable_default_tools,
          coding_agent: @coding_agent,
          assume_model_exists: @assume_model_exists,
          max_concurrent_tools: @max_concurrent_tools,
          hooks: @hooks,
          shared_across_delegations: @shared_across_delegations,
          # Permissions are core SDK functionality (not plugin-specific)
          default_permissions: @default_permissions,
          permissions: @agent_permissions,
        }.compact

        # Allow plugins to contribute their config for serialization
        # This enables plugin features (memory, skills, etc.) to be preserved
        # when cloning agents without SwarmSDK knowing about plugin-specific fields
        plugin_configs = SwarmSDK::PluginRegistry.all.map do |plugin|
          plugin.serialize_config(agent_definition: self)
        end

        # Merge plugin configs into base config
        # Later plugins override earlier ones if they have conflicting keys
        plugin_configs.reduce(base_config) { |acc, config| acc.merge(config) }
      end

      # Validate agent configuration and return warnings (non-fatal issues)
      #
      # Unlike validate! which raises exceptions for critical errors, this method
      # returns an array of warning hashes for non-fatal issues like:
      # - Model not found in registry (informs user, suggests alternatives)
      # - Context tracking unavailable (useful even with assume_model_exists)
      #
      # Note: Validation ALWAYS runs, even with assume_model_exists: true or base_url set.
      # The purpose is to inform the user about potential issues and suggest corrections,
      # not to block execution.
      #
      # @return [Array<Hash>] Array of warning hashes
      def validate
        warnings = []

        # Always validate model (even with assume_model_exists)
        # Warnings inform user about typos and context tracking limitations
        model_warning = validate_model
        warnings << model_warning if model_warning

        # Future: could add tool validation, delegate validation, etc.

        warnings
      end

      private

      # Validate that model exists in SwarmSDK's model registry
      #
      # Uses SwarmSDK's static models.json instead of RubyLLM's dynamic registry.
      # This provides stable, offline model validation without network calls.
      #
      # Process:
      # 1. Try to find model directly in models.json
      # 2. If not found, try to resolve as alias and find again
      # 3. If still not found, return warning with suggestions
      #
      # @return [Hash, nil] Warning hash if model not found, nil otherwise
      def validate_model
        # Try direct lookup first
        model_data = SwarmSDK::Models.all.find { |m| (m["id"] || m[:id]) == @model }

        # If not found, try alias resolution
        unless model_data
          resolved_id = SwarmSDK::Models.resolve_alias(@model)
          # Only search again if alias was different
          if resolved_id != @model
            model_data = SwarmSDK::Models.all.find { |m| (m["id"] || m[:id]) == resolved_id }
          end
        end

        if model_data
          nil # Model exists (either directly or via alias)
        else
          # Model not found - return warning with suggestions
          {
            type: :model_not_found,
            agent: @name,
            model: @model,
            error_message: "Unknown model: #{@model}",
            suggestions: SwarmSDK::Models.suggest_similar(@model),
          }
        end
      rescue StandardError => e
        # Return warning on error
        {
          type: :model_not_found,
          agent: @name,
          model: @model,
          error_message: e.message,
          suggestions: [],
        }
      end

      def build_full_system_prompt(custom_prompt)
        # Delegate to SystemPromptBuilder for all prompt construction logic
        # This keeps Definition focused on data storage while extracting complex logic
        SystemPromptBuilder.build(
          custom_prompt: custom_prompt,
          coding_agent: @coding_agent,
          disable_default_tools: @disable_default_tools,
          directory: @directory,
          definition: self,
        )
      end

      def parse_directory(directory_config)
        directory_config ||= "."
        File.expand_path(directory_config.to_s)
      end

      # Extract plugin-specific configuration keys from the config hash
      #
      # Standard SDK keys are filtered out, leaving only plugin-specific keys.
      # This allows plugins to add their own configuration without SDK modifications.
      #
      # @param config [Hash] Full agent configuration
      # @return [Hash] Plugin-specific configuration (keys not recognized by SDK)
      def extract_plugin_configs(config)
        standard_keys = [
          :name,
          :description,
          :model,
          :provider,
          :base_url,
          :api_version,
          :context_window,
          :parameters,
          :headers,
          :timeout,
          :bypass_permissions,
          :max_concurrent_tools,
          :assume_model_exists,
          :disable_default_tools,
          :coding_agent,
          :directory,
          :system_prompt,
          :tools,
          :delegates_to,
          :mcp_servers,
          :hooks,
          :default_permissions,
          :permissions,
          :shared_across_delegations,
          :directories,
        ]

        config.reject { |k, _| standard_keys.include?(k.to_sym) }
      end

      # Parse tools configuration with permissions support
      #
      # Tools can be specified as:
      # - Symbol: :Write (no permissions)
      # - Hash: { Write: { allowed_paths: [...] } } (with permissions)
      #
      # Returns array of tool configs:
      # [
      #   { name: :Read, permissions: nil },
      #   { name: :Write, permissions: { allowed_paths: [...] } }
      # ]
      def parse_tools_with_permissions(tools_config, default_permissions, agent_permissions)
        tools_array = Array(tools_config || [])

        tools_array.map do |tool_spec|
          case tool_spec
          when Symbol, String
            # Simple tool: :Write or "Write"
            tool_name = tool_spec.to_sym
            permissions = resolve_permissions(tool_name, default_permissions, agent_permissions)

            { name: tool_name, permissions: permissions }
          when Hash
            # Check if already in parsed format: { name: :Write, permissions: {...} }
            if tool_spec.key?(:name)
              # Already parsed - pass through as-is
              tool_spec
            else
              # Tool with inline permissions: { Write: { allowed_paths: [...] } }
              tool_name = tool_spec.keys.first.to_sym
              inline_permissions = tool_spec.values.first

              # Inline permissions override defaults
              { name: tool_name, permissions: inline_permissions }
            end
          else
            raise ConfigurationError, "Invalid tool specification: #{tool_spec.inspect}"
          end
        end
      end

      # Resolve permissions for a tool from defaults and agent-level overrides
      def resolve_permissions(tool_name, default_permissions, agent_permissions)
        # Agent-level permissions override defaults
        agent_permissions[tool_name] || default_permissions[tool_name]
      end

      # Inject default write permissions for security
      #
      # Write, Edit, and MultiEdit tools without explicit permissions are automatically
      # restricted to only write within the agent's directory. This prevents accidental
      # writes outside the agent's working scope.
      #
      # Default permission: { allowed_paths: ["**/*"] }
      # This is resolved relative to the agent's directory by the permissions system.
      #
      # Users can override by explicitly setting permissions for these tools.
      def inject_default_write_permissions(tools)
        write_tools = [:Write, :Edit, :MultiEdit]

        tools.map do |tool_config|
          tool_name = tool_config[:name]

          # If it's a write tool and has no permissions, inject default
          if write_tools.include?(tool_name) && tool_config[:permissions].nil?
            tool_config.merge(permissions: { allowed_paths: ["**/*"] })
          else
            tool_config
          end
        end
      end

      # Parse hooks configuration
      #
      # Handles two input formats:
      #
      # 1. DSL format (from Agent::Builder): Pre-parsed HookDefinition objects
      #    { event_type: [HookDefinition, ...] }
      #    These are applied directly in pass_4_configure_hooks
      #
      # 2. YAML format: Raw hash with shell command specifications
      #    hooks:
      #      pre_tool_use:
      #        - matcher: "Write|Edit"
      #          type: command
      #          command: "validate.sh"
      #    These are kept raw and processed by Hooks::Adapter in pass_5
      #
      # Returns:
      # - DSL: { event_type: [HookDefinition, ...] }
      # - YAML: Raw hash (for Hooks::Adapter)
      def parse_hooks(hooks_config)
        return {} if hooks_config.nil? || hooks_config.empty?

        # If already parsed from DSL (HookDefinition objects), return as-is
        if hooks_config.is_a?(Hash) && hooks_config.values.all? { |v| v.is_a?(Array) && v.all? { |item| item.is_a?(Hooks::Definition) } }
          return hooks_config
        end

        # For YAML hooks: validate structure but keep raw for Hooks::Adapter
        validate_yaml_hooks(hooks_config)

        # Return raw YAML - Hooks::Adapter will process in pass_5
        hooks_config
      end

      # Validate YAML hooks structure
      #
      # @param hooks_config [Hash] YAML hooks configuration
      # @return [void]
      def validate_yaml_hooks(hooks_config)
        hooks_config.each do |event_name, hook_specs|
          event_sym = event_name.to_sym

          # Validate event type
          unless Hooks::Registry::VALID_EVENTS.include?(event_sym)
            raise ConfigurationError,
              "Invalid hook event '#{event_name}' for agent '#{@name}'. " \
                "Valid events: #{Hooks::Registry::VALID_EVENTS.join(", ")}"
          end

          # Validate each hook spec structure
          Array(hook_specs).each do |spec|
            hook_type = spec[:type] || spec["type"]
            command = spec[:command] || spec["command"]

            raise ConfigurationError, "Hook missing 'type' field for event #{event_name}" unless hook_type
            raise ConfigurationError, "Hook missing 'command' field for event #{event_name}" if hook_type.to_s == "command" && !command
          end
        end
      end

      def validate!
        raise ConfigurationError, "Agent '#{@name}' missing required 'description' field" unless @description

        # Validate api_version can only be set for OpenAI-compatible providers
        if @api_version
          openai_compatible = ["openai", "deepseek", "perplexity", "mistral", "openrouter"]
          unless openai_compatible.include?(@provider.to_s)
            raise ConfigurationError,
              "Agent '#{@name}' has api_version set, but provider is '#{@provider}'. " \
                "api_version can only be used with OpenAI-compatible providers: #{openai_compatible.join(", ")}"
          end

          # Validate api_version value
          valid_versions = ["v1/chat/completions", "v1/responses"]
          unless valid_versions.include?(@api_version)
            raise ConfigurationError,
              "Agent '#{@name}' has invalid api_version '#{@api_version}'. " \
                "Valid values: #{valid_versions.join(", ")}"
          end
        end

        unless File.directory?(@directory)
          raise ConfigurationError, "Directory '#{@directory}' for agent '#{@name}' does not exist"
        end
      end
    end
  end
end
