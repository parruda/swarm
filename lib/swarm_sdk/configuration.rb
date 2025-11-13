# frozen_string_literal: true

module SwarmSDK
  class Configuration
    ENV_VAR_WITH_DEFAULT_PATTERN = /\$\{([^:}]+)(:=([^}]*))?\}/

    attr_reader :swarm_name, :swarm_id, :lead_agent, :agents, :all_agents_config, :swarm_hooks, :all_agents_hooks, :scratchpad_enabled, :nodes, :start_node, :external_swarms

    class << self
      # Load configuration from YAML file
      #
      # Convenience method that reads the file and uses the file's directory
      # as the base directory for resolving agent file paths.
      #
      # @param path [String, Pathname] Path to YAML configuration file
      # @return [Configuration] Validated configuration instance
      # @raise [ConfigurationError] If file not found or invalid
      def load_file(path)
        path = Pathname.new(path).expand_path

        unless path.exist?
          raise ConfigurationError, "Configuration file not found: #{path}"
        end

        yaml_content = File.read(path)
        base_dir = path.dirname

        new(yaml_content, base_dir: base_dir).tap(&:load_and_validate)
      rescue Errno::ENOENT
        raise ConfigurationError, "Configuration file not found: #{path}"
      end
    end

    # Initialize configuration from YAML string
    #
    # @param yaml_content [String] YAML configuration content
    # @param base_dir [String, Pathname] Base directory for resolving agent file paths (default: Dir.pwd)
    def initialize(yaml_content, base_dir: Dir.pwd)
      raise ArgumentError, "yaml_content cannot be nil" if yaml_content.nil?
      raise ArgumentError, "base_dir cannot be nil" if base_dir.nil?

      @yaml_content = yaml_content
      @base_dir = Pathname.new(base_dir).expand_path
      @swarm_id = nil # Optional swarm ID from YAML
      @agents = {} # Parsed agent configs (hashes, not Definitions)
      @all_agents_config = {} # Settings applied to all agents
      @swarm_hooks = {} # Swarm-level hooks (swarm_start, swarm_stop)
      @all_agents_hooks = {} # Hooks applied to all agents
      @external_swarms = {} # External swarms for composable swarms
      @nodes = {} # Parsed node configs (hashes)
      @start_node = nil # Starting node for workflows
    end

    def load_and_validate
      @config = YAML.safe_load(@yaml_content, permitted_classes: [Symbol], aliases: true)

      unless @config.is_a?(Hash)
        raise ConfigurationError, "Invalid YAML syntax: configuration must be a Hash"
      end

      @config = Utils.symbolize_keys(@config)
      interpolate_env_vars!(@config)
      validate_version
      load_all_agents_config
      load_hooks_config
      validate_swarm
      load_agents
      load_nodes
      detect_circular_dependencies
      self
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "Invalid YAML syntax: #{e.message}"
    end

    def agent_names
      @agents.keys
    end

    def connections_for(agent_name)
      agent_config = @agents[agent_name]
      return [] unless agent_config

      # Extract delegates_to from hash and convert to symbols
      delegates = agent_config[:delegates_to] || []
      Array(delegates).map(&:to_sym)
    end

    # Convert configuration to Swarm or Workflow using DSL
    #
    # This method translates YAML configuration to Ruby DSL calls.
    # The appropriate builder (Swarm::Builder or Workflow::Builder) handles
    # all validation, merging, and construction.
    #
    # @param allow_filesystem_tools [Boolean, nil] Whether to allow filesystem tools (nil uses global setting)
    # @return [Swarm, Workflow] Configured swarm or workflow
    def to_swarm(allow_filesystem_tools: nil)
      # Choose builder based on whether nodes are defined
      builder = if @nodes.any?
        Workflow::Builder.new(allow_filesystem_tools: allow_filesystem_tools)
      else
        Swarm::Builder.new(allow_filesystem_tools: allow_filesystem_tools)
      end

      # Translate basic config to DSL
      builder.id(@swarm_id) if @swarm_id
      builder.name(@swarm_name)
      builder.scratchpad(@scratchpad_mode)

      # Set lead or start_node based on builder type
      if builder.is_a?(Swarm::Builder)
        builder.lead(@lead_agent)
      else
        builder.start_node(@start_node)
      end

      # Translate external swarms
      if @external_swarms&.any?
        builder.swarms do
          @external_swarms.each do |name, config|
            source = config[:source]
            case source[:type]
            when :file
              register(name, file: source[:value], keep_context: config[:keep_context])
            when :yaml
              register(name, yaml: source[:value], keep_context: config[:keep_context])
            else
              raise ConfigurationError, "Unknown source type: #{source[:type]}"
            end
          end
        end
      end

      # Translate all_agents config to DSL (if present)
      translate_all_agents(builder) if @all_agents_config.any?

      # Translate agents to DSL
      translate_agents(builder)

      # Translate swarm-level hooks to DSL (if present)
      translate_swarm_hooks(builder) if @swarm_hooks.any?

      # Translate nodes to DSL (if using Workflow::Builder)
      if builder.is_a?(Workflow::Builder)
        translate_nodes(builder)
      end

      # Build the swarm or workflow
      builder.build_swarm
    end

    private

    def parse_scratchpad_mode(value)
      return :disabled if value.nil? # Default

      # Convert strings from YAML to symbols
      value = value.to_sym if value.is_a?(String)

      # Validate symbols
      case value
      when :enabled, :disabled, :per_node
        value
      else
        raise ConfigurationError,
          "Invalid scratchpad mode: #{value.inspect}. Use :enabled, :per_node, or :disabled"
      end
    end

    def interpolate_env_vars!(obj)
      case obj
      when String
        interpolate_env_string(obj)
      when Hash
        obj.transform_values! { |v| interpolate_env_vars!(v) }
      when Array
        obj.map! { |v| interpolate_env_vars!(v) }
      else
        obj
      end
    end

    def interpolate_env_string(str)
      str.gsub(ENV_VAR_WITH_DEFAULT_PATTERN) do |_match|
        env_var = Regexp.last_match(1)
        has_default = Regexp.last_match(2)
        default_value = Regexp.last_match(3)

        if ENV.key?(env_var)
          ENV[env_var]
        elsif has_default
          default_value || ""
        else
          raise ConfigurationError, "Environment variable '#{env_var}' is not set"
        end
      end
    end

    def validate_version
      version = @config[:version]
      raise ConfigurationError, "Missing 'version' field in configuration" unless version
      raise ConfigurationError, "SwarmSDK requires version: 2 configuration. Got version: #{version}" unless version == 2
    end

    def load_all_agents_config
      return unless @config[:swarm]

      @all_agents_config = @config[:swarm][:all_agents] || {}

      # Convert disable_default_tools array elements to symbols
      if @all_agents_config[:disable_default_tools].is_a?(Array)
        @all_agents_config[:disable_default_tools] = @all_agents_config[:disable_default_tools].map(&:to_sym)
      end
    end

    def load_hooks_config
      return unless @config[:swarm]

      # Load swarm-level hooks (only swarm_start, swarm_stop allowed)
      @swarm_hooks = Utils.symbolize_keys(@config[:swarm][:hooks] || {})

      # Load all_agents hooks (applied as swarm defaults)
      if @config[:swarm][:all_agents]
        @all_agents_hooks = Utils.symbolize_keys(@config[:swarm][:all_agents][:hooks] || {})
      end
    end

    def validate_swarm
      raise ConfigurationError, "Missing 'swarm' field in configuration" unless @config[:swarm]

      swarm = @config[:swarm]
      raise ConfigurationError, "Missing 'name' field in swarm configuration" unless swarm[:name]
      raise ConfigurationError, "Missing 'agents' field in swarm configuration" unless swarm[:agents]
      raise ConfigurationError, "Missing 'lead' field in swarm configuration" unless swarm[:lead]
      raise ConfigurationError, "No agents defined" if swarm[:agents].empty?

      @swarm_name = swarm[:name]
      @swarm_id = swarm[:id] # Optional - will auto-generate if missing
      @lead_agent = swarm[:lead].to_sym # Convert to symbol for consistency
      @scratchpad_mode = parse_scratchpad_mode(swarm[:scratchpad])

      # Load external swarms for composable swarms
      load_external_swarms(swarm[:swarms]) if swarm[:swarms]
    end

    def load_external_swarms(swarms_config)
      @external_swarms = {}
      swarms_config.each do |name, config|
        # Determine source type: file, yaml string, or inline swarm definition
        source = if config[:file]
          # File path - resolve relative to base_dir
          file_path = if config[:file].start_with?("/")
            config[:file]
          else
            (@base_dir / config[:file]).to_s
          end
          { type: :file, value: file_path }
        elsif config[:yaml]
          # YAML string provided directly
          { type: :yaml, value: config[:yaml] }
        elsif config[:swarm]
          # Inline swarm definition - convert to YAML string
          inline_config = {
            version: 2,
            swarm: config[:swarm],
          }
          yaml_string = Utils.hash_to_yaml(inline_config)
          { type: :yaml, value: yaml_string }
        else
          raise ConfigurationError, "Swarm '#{name}' must specify either 'file:', 'yaml:', or 'swarm:' (inline definition)"
        end

        @external_swarms[name.to_sym] = {
          source: source,
          keep_context: config.fetch(:keep_context, true),
        }
      end
    end

    def load_agents
      swarm_agents = @config[:swarm][:agents]

      swarm_agents.each do |name, agent_config|
        # Support three formats:
        # 1. String: assistant: "agents/assistant.md" (file path)
        # 2. Hash with agent_file: assistant: { agent_file: "..." }
        # 3. Hash with inline definition: assistant: { description: "...", model: "..." }
        # 4. nil: Invalid (will be caught when building swarm)

        parsed_config = if agent_config.nil?
          # Null config - store empty hash, will fail during swarm building
          {}
        elsif agent_config.is_a?(String)
          # Format 1: Direct file path as string
          { agent_file: agent_config }
        elsif agent_config.is_a?(Hash) && agent_config[:agent_file]
          # Format 2: Hash with agent_file key
          agent_config
        else
          # Format 3: Inline definition
          agent_config || {}
        end

        # Validate required fields for inline definitions (strict validation for YAML)
        # File-based agents are validated when loaded
        if parsed_config[:agent_file].nil? && parsed_config[:description].nil?
          raise ConfigurationError,
            "Agent '#{name}' missing required 'description' field"
        end

        @agents[name] = parsed_config
      end

      unless @agents.key?(@lead_agent)
        raise ConfigurationError, "Lead agent '#{@lead_agent}' not found in agents"
      end
    end

    def load_nodes
      return unless @config[:swarm][:nodes]

      @nodes = Utils.symbolize_keys(@config[:swarm][:nodes])
      @start_node = @config[:swarm][:start_node]&.to_sym

      # Validate start_node is required if nodes defined
      if @nodes.any? && !@start_node
        raise ConfigurationError, "start_node required when nodes are defined"
      end

      # Validate start_node exists
      if @start_node && !@nodes.key?(@start_node)
        raise ConfigurationError, "start_node '#{@start_node}' not found in nodes"
      end

      # Basic node structure validation
      @nodes.each do |node_name, node_config|
        unless node_config.is_a?(Hash)
          raise ConfigurationError, "Node '#{node_name}' must be a hash"
        end

        # Validate agents if present (optional for agent-less nodes)
        if node_config[:agents]
          unless node_config[:agents].is_a?(Array)
            raise ConfigurationError, "Node '#{node_name}' agents must be an array"
          end

          # Validate each agent config
          node_config[:agents].each do |agent_config|
            unless agent_config.is_a?(Hash) && agent_config[:agent]
              raise ConfigurationError,
                "Node '#{node_name}' agents must be hashes with 'agent' key"
            end

            # Validate agent exists in swarm agents
            agent_sym = agent_config[:agent].to_sym
            unless @agents.key?(agent_sym)
              raise ConfigurationError,
                "Node '#{node_name}' references undefined agent '#{agent_config[:agent]}'"
            end
          end
        end

        # Validate dependencies if present
        next unless node_config[:dependencies]
        unless node_config[:dependencies].is_a?(Array)
          raise ConfigurationError, "Node '#{node_name}' dependencies must be an array"
        end

        # Validate each dependency exists
        node_config[:dependencies].each do |dep|
          dep_sym = dep.to_sym
          unless @nodes.key?(dep_sym)
            raise ConfigurationError,
              "Node '#{node_name}' depends on undefined node '#{dep}'"
          end
        end
      end
    end

    # Translate all_agents configuration to DSL
    #
    # @param builder [Swarm::Builder] DSL builder instance
    # @return [void]
    def translate_all_agents(builder)
      # Capture instance variables for block scope
      all_agents_cfg = @all_agents_config
      all_agents_hks = @all_agents_hooks

      builder.all_agents do
        # Translate each all_agents field to DSL method calls
        tools(*all_agents_cfg[:tools]) if all_agents_cfg[:tools]&.any?
        model(all_agents_cfg[:model]) if all_agents_cfg[:model]
        provider(all_agents_cfg[:provider]) if all_agents_cfg[:provider]
        base_url(all_agents_cfg[:base_url]) if all_agents_cfg[:base_url]
        api_version(all_agents_cfg[:api_version]) if all_agents_cfg[:api_version]
        timeout(all_agents_cfg[:timeout]) if all_agents_cfg[:timeout]
        parameters(all_agents_cfg[:parameters]) if all_agents_cfg[:parameters]
        headers(all_agents_cfg[:headers]) if all_agents_cfg[:headers]
        coding_agent(all_agents_cfg[:coding_agent]) unless all_agents_cfg[:coding_agent].nil?
        disable_default_tools(all_agents_cfg[:disable_default_tools]) unless all_agents_cfg[:disable_default_tools].nil?

        # Translate all_agents hooks
        if all_agents_hks.any?
          all_agents_hks.each do |event, hook_specs|
            Array(hook_specs).each do |spec|
              matcher = spec[:matcher]
              hook(event, matcher: matcher, command: spec[:command], timeout: spec[:timeout]) if spec[:type] == "command"
            end
          end
        end

        # Permissions - set directly as hash (YAML doesn't use DSL block syntax)
        self.permissions_hash = all_agents_cfg[:permissions] if all_agents_cfg[:permissions]
      end
    end

    # Translate agents to DSL
    #
    # @param builder [Swarm::Builder] DSL builder instance
    # @return [void]
    def translate_agents(builder)
      @agents.each do |name, agent_config|
        translate_agent(builder, name, agent_config)
      rescue ConfigurationError => e
        # Re-raise with agent context for better error messages
        raise ConfigurationError, "Error in swarm.agents.#{name}: #{e.message}"
      end
    end

    # Translate single agent to DSL
    #
    # @param builder [Swarm::Builder] DSL builder instance
    # @param name [Symbol] Agent name
    # @param config [Hash] Agent configuration
    # @return [void]
    def translate_agent(builder, name, config)
      if config[:agent_file]
        # Load from file
        agent_file_path = resolve_agent_file_path(config[:agent_file])

        unless File.exist?(agent_file_path)
          raise ConfigurationError, "Agent file not found: #{agent_file_path}"
        end

        content = File.read(agent_file_path)

        # Check if there are overrides besides agent_file
        overrides = config.except(:agent_file)

        if overrides.any?
          # Load from markdown with DSL overrides
          builder.agent(name, content, &create_agent_config_block(overrides))
        else
          # Load from markdown only
          builder.agent(name, content)
        end
      else
        # Inline definition - translate to DSL
        builder.agent(name, &create_agent_config_block(config))
      end
    rescue StandardError => e
      raise ConfigurationError, "Error loading agent '#{name}': #{e.message}"
    end

    # Create a block that configures an agent builder with the given config
    #
    # Returns a proc that can be passed to builder.agent
    #
    # @param config [Hash] Agent configuration hash
    # @return [Proc] Block that configures agent builder
    def create_agent_config_block(config)
      proc do
        description(config[:description]) if config[:description]
        model(config[:model]) if config[:model]
        provider(config[:provider]) if config[:provider]
        base_url(config[:base_url]) if config[:base_url]
        api_version(config[:api_version]) if config[:api_version]
        context_window(config[:context_window]) if config[:context_window]
        system_prompt(config[:system_prompt]) if config[:system_prompt]
        directory(config[:directory]) if config[:directory]
        timeout(config[:timeout]) if config[:timeout]
        parameters(config[:parameters]) if config[:parameters]
        headers(config[:headers]) if config[:headers]
        coding_agent(config[:coding_agent]) unless config[:coding_agent].nil?
        bypass_permissions(config[:bypass_permissions]) if config[:bypass_permissions]
        disable_default_tools(config[:disable_default_tools]) unless config[:disable_default_tools].nil?
        shared_across_delegations(config[:shared_across_delegations]) unless config[:shared_across_delegations].nil?

        # Tools
        if config[:tools]&.any?
          tool_names = config[:tools].map { |t| t.is_a?(Hash) ? t[:name] : t }
          tools(*tool_names)
        end

        # Delegation
        delegates_to(*config[:delegates_to]) if config[:delegates_to]&.any?

        # MCP servers
        config[:mcp_servers]&.each do |server|
          mcp_server(server[:name], **server.except(:name))
        end

        # Hooks (YAML-style command hooks)
        config[:hooks]&.each do |event, hook_specs|
          Array(hook_specs).each do |spec|
            matcher = spec[:matcher]
            hook(event, matcher: matcher, command: spec[:command], timeout: spec[:timeout]) if spec[:type] == "command"
          end
        end

        # Memory
        if config[:memory]
          memory do
            directory(config[:memory][:directory]) if config[:memory][:directory]
            adapter(config[:memory][:adapter]) if config[:memory][:adapter]
            mode(config[:memory][:mode]) if config[:memory][:mode]
          end
        end

        # Permissions - set directly as hash (YAML doesn't use DSL block syntax)
        self.permissions_hash = config[:permissions] if config[:permissions]
      end
    end

    # Translate swarm-level hooks to DSL
    #
    # @param builder [Swarm::Builder] Swarm builder instance
    # @return [void]
    def translate_swarm_hooks(builder)
      @swarm_hooks.each do |event, hook_specs|
        Array(hook_specs).each do |spec|
          if spec[:type] == "command"
            builder.hook(event, command: spec[:command], timeout: spec[:timeout])
          end
        end
      end
    end

    # Translate nodes to DSL
    #
    # @param builder [Swarm::Builder] Swarm builder instance
    # @return [void]
    def translate_nodes(builder)
      @nodes.each do |node_name, node_config|
        builder.node(node_name) do
          # Translate agents
          node_config[:agents]&.each do |agent_config|
            agent_name = agent_config[:agent].to_sym
            delegates = agent_config[:delegates_to] || []
            reset_ctx = agent_config.key?(:reset_context) ? agent_config[:reset_context] : true
            tools_override = agent_config[:tools]

            # Build agent config with fluent API
            agent_cfg = agent(agent_name, reset_context: reset_ctx)

            # Apply delegation if present
            agent_cfg = agent_cfg.delegates_to(*delegates) if delegates.any?

            # Apply tools override if present
            agent_cfg.tools(*tools_override) if tools_override # Return config (finalize will be called automatically)
          end

          # Translate dependencies
          depends_on(*node_config[:dependencies]) if node_config[:dependencies]&.any?

          # Translate lead override
          lead(node_config[:lead].to_sym) if node_config[:lead]

          # Translate transformers
          if node_config[:input_command]
            input_command(node_config[:input_command], timeout: node_config[:input_timeout] || 60)
          end

          if node_config[:output_command]
            output_command(node_config[:output_command], timeout: node_config[:output_timeout] || 60)
          end
        end
      end
    end

    # Resolve agent file path relative to base_dir
    #
    # @param file_path [String] Relative or absolute file path
    # @return [String] Resolved absolute path
    def resolve_agent_file_path(file_path)
      return file_path if Pathname.new(file_path).absolute?

      @base_dir.join(file_path).to_s
    end

    def detect_circular_dependencies
      @agents.each_key do |agent_name|
        visited = Set.new
        path = []
        detect_cycle_from(agent_name, visited, path)
      end
    end

    def detect_cycle_from(agent_name, visited, path)
      return if visited.include?(agent_name)

      if path.include?(agent_name)
        cycle_start = path.index(agent_name)
        cycle = path[cycle_start..] + [agent_name]
        raise CircularDependencyError, "Circular dependency detected: #{cycle.join(" -> ")}"
      end

      path.push(agent_name)
      connections_for(agent_name).each do |connection|
        connection_sym = connection.to_sym # Convert to symbol for lookup

        # Skip external swarms - they are not local agents and don't have circular dependency issues
        next if @external_swarms.key?(connection_sym)

        unless @agents.key?(connection_sym)
          raise ConfigurationError, "Agent '#{agent_name}' delegates to unknown target '#{connection}' (not a local agent or registered swarm)"
        end

        detect_cycle_from(connection_sym, visited, path)
      end
      path.pop
      visited.add(agent_name)
    end
  end
end
