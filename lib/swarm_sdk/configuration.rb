# frozen_string_literal: true

module SwarmSDK
  class Configuration
    ENV_VAR_WITH_DEFAULT_PATTERN = /\$\{([^:}]+)(:=([^}]*))?\}/

    attr_reader :config_type, :swarm_name, :swarm_id, :lead_agent, :start_node, :agents, :all_agents_config, :swarm_hooks, :all_agents_hooks, :scratchpad_enabled, :nodes, :external_swarms

    class << self
      # Load configuration from YAML file
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
      @config_type = nil # :swarm or :workflow (detected during load)
      @swarm_id = nil
      @swarm_name = nil
      @lead_agent = nil
      @start_node = nil
      @agents = {}
      @all_agents_config = {}
      @swarm_hooks = {}
      @all_agents_hooks = {}
      @external_swarms = {}
      @nodes = {}
      @scratchpad_mode = :disabled
    end

    def load_and_validate
      @config = YAML.safe_load(@yaml_content, permitted_classes: [Symbol], aliases: true)

      unless @config.is_a?(Hash)
        raise ConfigurationError, "Invalid YAML syntax: configuration must be a Hash"
      end

      @config = Utils.symbolize_keys(@config)
      interpolate_env_vars!(@config)

      validate_version
      detect_and_validate_type
      load_common_config
      load_type_specific_config
      load_agents
      load_nodes if @config_type == :workflow # Load nodes after agents (for validation)
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

      delegates = agent_config[:delegates_to] || []
      Array(delegates).map(&:to_sym)
    end

    # Convert configuration to Swarm or Workflow using appropriate builder
    #
    # @param allow_filesystem_tools [Boolean, nil] Whether to allow filesystem tools (nil uses global setting)
    # @return [Swarm, Workflow] Configured swarm or workflow
    def to_swarm(allow_filesystem_tools: nil)
      builder = create_builder(allow_filesystem_tools)

      translate_common_config(builder)
      translate_type_specific_config(builder)
      translate_agents(builder)
      translate_hooks(builder)

      builder.build_swarm
    end

    private

    # Detect configuration type and validate structure
    #
    # Checks for both swarm: and workflow: keys, validates mutual exclusivity,
    # and sets @config_type based on which is present.
    def detect_and_validate_type
      has_swarm = @config.key?(:swarm)
      has_workflow = @config.key?(:workflow)

      # Validate mutual exclusivity
      if has_swarm && has_workflow
        raise ConfigurationError, "Cannot have both 'swarm:' and 'workflow:' keys. Use one or the other."
      end

      unless has_swarm || has_workflow
        raise ConfigurationError, "Missing 'swarm:' or 'workflow:' key in configuration"
      end

      @config_type = has_swarm ? :swarm : :workflow
      @root_config = @config[@config_type]
    end

    # Load configuration common to both swarms and workflows
    def load_common_config
      raise ConfigurationError, "Missing 'name' field in #{@config_type} configuration" unless @root_config[:name]

      @swarm_name = @root_config[:name]
      @swarm_id = @root_config[:id]
      @scratchpad_mode = parse_scratchpad_mode(@root_config[:scratchpad])

      load_all_agents_config
      load_hooks_config
      load_external_swarms(@root_config[:swarms]) if @root_config[:swarms]
    end

    # Load type-specific configuration
    def load_type_specific_config
      if @config_type == :swarm
        load_swarm_config
      else
        load_workflow_config
      end
    end

    # Load swarm-specific configuration
    def load_swarm_config
      raise ConfigurationError, "Missing 'lead' field in swarm configuration" unless @root_config[:lead]
      raise ConfigurationError, "Missing 'agents' field in swarm configuration" unless @root_config[:agents]

      @lead_agent = @root_config[:lead].to_sym

      # Validate no workflow-specific fields
      if @root_config[:nodes] || @root_config[:start_node]
        raise ConfigurationError, "Swarm configuration cannot have 'nodes' or 'start_node'. Use 'workflow:' key instead."
      end
    end

    # Load workflow-specific configuration
    def load_workflow_config
      raise ConfigurationError, "Missing 'start_node' field in workflow configuration" unless @root_config[:start_node]
      raise ConfigurationError, "Missing 'nodes' field in workflow configuration" unless @root_config[:nodes]
      raise ConfigurationError, "Missing 'agents' field in workflow configuration" unless @root_config[:agents]

      @start_node = @root_config[:start_node].to_sym

      # Validate no swarm-specific fields
      if @root_config[:lead]
        raise ConfigurationError, "Workflow configuration cannot have 'lead'. Use 'start_node' instead."
      end

      # NOTE: load_nodes() is called later in load_and_validate after agents are loaded
    end

    def load_all_agents_config
      @all_agents_config = @root_config[:all_agents] || {}

      # Convert disable_default_tools array elements to symbols
      if @all_agents_config[:disable_default_tools].is_a?(Array)
        @all_agents_config[:disable_default_tools] = @all_agents_config[:disable_default_tools].map(&:to_sym)
      end
    end

    def load_hooks_config
      # Load swarm/workflow-level hooks
      @swarm_hooks = Utils.symbolize_keys(@root_config[:hooks] || {})

      # Load all_agents hooks
      if @root_config[:all_agents]
        @all_agents_hooks = Utils.symbolize_keys(@root_config[:all_agents][:hooks] || {})
      end
    end

    def load_external_swarms(swarms_config)
      @external_swarms = {}
      swarms_config.each do |name, config|
        source = if config[:file]
          file_path = if config[:file].start_with?("/")
            config[:file]
          else
            (@base_dir / config[:file]).to_s
          end
          { type: :file, value: file_path }
        elsif config[:yaml]
          { type: :yaml, value: config[:yaml] }
        elsif config[:swarm]
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
      swarm_agents = @root_config[:agents]
      raise ConfigurationError, "No agents defined" if swarm_agents.empty?

      swarm_agents.each do |name, agent_config|
        parsed_config = if agent_config.nil?
          {}
        elsif agent_config.is_a?(String)
          { agent_file: agent_config }
        elsif agent_config.is_a?(Hash) && agent_config[:agent_file]
          agent_config
        else
          agent_config || {}
        end

        # Validate required fields for inline definitions
        if parsed_config[:agent_file].nil? && parsed_config[:description].nil?
          raise ConfigurationError,
            "Agent '#{name}' missing required 'description' field"
        end

        @agents[name] = parsed_config
      end

      # Validate lead/start_node agent exists
      if @config_type == :swarm
        unless @agents.key?(@lead_agent)
          raise ConfigurationError, "Lead agent '#{@lead_agent}' not found in agents"
        end
      end
    end

    def load_nodes
      @nodes = Utils.symbolize_keys(@root_config[:nodes])

      # Validate start_node exists
      unless @nodes.key?(@start_node)
        raise ConfigurationError, "start_node '#{@start_node}' not found in nodes"
      end

      # Basic node structure validation
      @nodes.each do |node_name, node_config|
        unless node_config.is_a?(Hash)
          raise ConfigurationError, "Node '#{node_name}' must be a hash"
        end

        # Validate agents if present
        if node_config[:agents]
          unless node_config[:agents].is_a?(Array)
            raise ConfigurationError, "Node '#{node_name}' agents must be an array"
          end

          node_config[:agents].each do |agent_config|
            unless agent_config.is_a?(Hash) && agent_config[:agent]
              raise ConfigurationError,
                "Node '#{node_name}' agents must be hashes with 'agent' key"
            end

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

        node_config[:dependencies].each do |dep|
          dep_sym = dep.to_sym
          unless @nodes.key?(dep_sym)
            raise ConfigurationError,
              "Node '#{node_name}' depends on undefined node '#{dep}'"
          end
        end
      end
    end

    def parse_scratchpad_mode(value)
      return :disabled if value.nil?

      value = value.to_sym if value.is_a?(String)

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

    def create_builder(allow_filesystem_tools)
      if @config_type == :swarm
        Swarm::Builder.new(allow_filesystem_tools: allow_filesystem_tools)
      else
        Workflow::Builder.new(allow_filesystem_tools: allow_filesystem_tools)
      end
    end

    def translate_common_config(builder)
      builder.id(@swarm_id) if @swarm_id
      builder.name(@swarm_name)
      builder.scratchpad(@scratchpad_mode)

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

      # Translate all_agents config (if present)
      translate_all_agents(builder) if @all_agents_config.any?
    end

    def translate_type_specific_config(builder)
      if @config_type == :swarm
        builder.lead(@lead_agent)
      else
        builder.start_node(@start_node)
        translate_nodes(builder)
      end
    end

    def translate_hooks(builder)
      # Translate swarm-level hooks (swarm_start, swarm_stop)
      return if @swarm_hooks.none?

      @swarm_hooks.each do |event, hook_specs|
        Array(hook_specs).each do |spec|
          if spec[:type] == "command"
            builder.hook(event, command: spec[:command], timeout: spec[:timeout])
          end
        end
      end
    end

    # Translate all_agents configuration to DSL
    def translate_all_agents(builder)
      all_agents_cfg = @all_agents_config
      all_agents_hks = @all_agents_hooks

      builder.all_agents do
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

        # Permissions
        self.permissions_hash = all_agents_cfg[:permissions] if all_agents_cfg[:permissions]
      end
    end

    # Translate agents to DSL
    def translate_agents(builder)
      @agents.each do |name, agent_config|
        translate_agent(builder, name, agent_config)
      rescue ConfigurationError => e
        raise ConfigurationError, "Error in #{@config_type}.agents.#{name}: #{e.message}"
      end
    end

    # Translate single agent to DSL
    def translate_agent(builder, name, config)
      if config[:agent_file]
        agent_file_path = resolve_agent_file_path(config[:agent_file])

        unless File.exist?(agent_file_path)
          raise ConfigurationError, "Agent file not found: #{agent_file_path}"
        end

        content = File.read(agent_file_path)
        overrides = config.except(:agent_file)

        if overrides.any?
          builder.agent(name, content, &create_agent_config_block(overrides))
        else
          builder.agent(name, content)
        end
      else
        builder.agent(name, &create_agent_config_block(config))
      end
    rescue StandardError => e
      raise ConfigurationError, "Error loading agent '#{name}': #{e.message}"
    end

    # Create a block that configures an agent builder
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

        # Hooks
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

        # Permissions
        self.permissions_hash = config[:permissions] if config[:permissions]
      end
    end

    # Translate nodes to DSL
    def translate_nodes(builder)
      @nodes.each do |node_name, node_config|
        builder.node(node_name) do
          # Translate agents
          node_config[:agents]&.each do |agent_config|
            agent_name = agent_config[:agent].to_sym
            delegates = agent_config[:delegates_to] || []
            reset_ctx = agent_config.key?(:reset_context) ? agent_config[:reset_context] : true
            tools_override = agent_config[:tools]

            agent_cfg = agent(agent_name, reset_context: reset_ctx)
            agent_cfg = agent_cfg.delegates_to(*delegates) if delegates.any?
            agent_cfg.tools(*tools_override) if tools_override
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
        connection_sym = connection.to_sym

        # Skip external swarms
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
