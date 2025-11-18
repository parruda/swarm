# frozen_string_literal: true

module SwarmSDK
  class Configuration
    # Handles YAML parsing, validation, and normalization
    #
    # This class is responsible for:
    # - Loading and parsing YAML content
    # - Validating configuration structure
    # - Normalizing data (symbolizing keys, env interpolation)
    # - Detecting configuration type (swarm vs workflow)
    # - Loading agents and nodes
    # - Detecting circular dependencies
    #
    # After parsing, the parsed data can be translated to a Swarm/Workflow
    # using the Translator class.
    class Parser
      ENV_VAR_WITH_DEFAULT_PATTERN = /\$\{([^:}]+)(:=([^}]*))?\}/

      attr_reader :config_type,
        :swarm_name,
        :swarm_id,
        :lead_agent,
        :start_node,
        :agents,
        :all_agents_config,
        :swarm_hooks,
        :all_agents_hooks,
        :scratchpad_mode,
        :nodes,
        :external_swarms

      def initialize(yaml_content, base_dir:)
        @yaml_content = yaml_content
        @base_dir = Pathname.new(base_dir).expand_path
        @config_type = nil
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

      def parse
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
        load_nodes if @config_type == :workflow
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

      attr_reader :base_dir

      private

      def validate_version
        version = @config[:version]
        raise ConfigurationError, "Missing 'version' field in configuration" unless version
        raise ConfigurationError, "SwarmSDK requires version: 2 configuration. Got version: #{version}" unless version == 2
      end

      def detect_and_validate_type
        has_swarm = @config.key?(:swarm)
        has_workflow = @config.key?(:workflow)

        if has_swarm && has_workflow
          raise ConfigurationError, "Cannot have both 'swarm:' and 'workflow:' keys. Use one or the other."
        end

        unless has_swarm || has_workflow
          raise ConfigurationError, "Missing 'swarm:' or 'workflow:' key in configuration"
        end

        @config_type = has_swarm ? :swarm : :workflow
        @root_config = @config[@config_type]
      end

      def load_common_config
        raise ConfigurationError, "Missing 'name' field in #{@config_type} configuration" unless @root_config[:name]

        @swarm_name = @root_config[:name]
        @swarm_id = @root_config[:id]
        @scratchpad_mode = parse_scratchpad_mode(@root_config[:scratchpad])

        load_all_agents_config
        load_hooks_config
        load_external_swarms(@root_config[:swarms]) if @root_config[:swarms]
      end

      def load_type_specific_config
        if @config_type == :swarm
          load_swarm_config
        else
          load_workflow_config
        end
      end

      def load_swarm_config
        raise ConfigurationError, "Missing 'lead' field in swarm configuration" unless @root_config[:lead]
        raise ConfigurationError, "Missing 'agents' field in swarm configuration" unless @root_config[:agents]

        @lead_agent = @root_config[:lead].to_sym

        if @root_config[:nodes] || @root_config[:start_node]
          raise ConfigurationError, "Swarm configuration cannot have 'nodes' or 'start_node'. Use 'workflow:' key instead."
        end
      end

      def load_workflow_config
        raise ConfigurationError, "Missing 'start_node' field in workflow configuration" unless @root_config[:start_node]
        raise ConfigurationError, "Missing 'nodes' field in workflow configuration" unless @root_config[:nodes]
        raise ConfigurationError, "Missing 'agents' field in workflow configuration" unless @root_config[:agents]

        @start_node = @root_config[:start_node].to_sym

        if @root_config[:lead]
          raise ConfigurationError, "Workflow configuration cannot have 'lead'. Use 'start_node' instead."
        end
      end

      def load_all_agents_config
        @all_agents_config = @root_config[:all_agents] || {}

        if @all_agents_config[:disable_default_tools].is_a?(Array)
          @all_agents_config[:disable_default_tools] = @all_agents_config[:disable_default_tools].map(&:to_sym)
        end
      end

      def load_hooks_config
        @swarm_hooks = Utils.symbolize_keys(@root_config[:hooks] || {})

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

          if parsed_config[:agent_file].nil? && parsed_config[:description].nil?
            raise ConfigurationError,
              "Agent '#{name}' missing required 'description' field"
          end

          @agents[name] = parsed_config
        end

        if @config_type == :swarm
          unless @agents.key?(@lead_agent)
            raise ConfigurationError, "Lead agent '#{@lead_agent}' not found in agents"
          end
        end
      end

      def load_nodes
        @nodes = Utils.symbolize_keys(@root_config[:nodes])

        unless @nodes.key?(@start_node)
          raise ConfigurationError, "start_node '#{@start_node}' not found in nodes"
        end

        @nodes.each do |node_name, node_config|
          unless node_config.is_a?(Hash)
            raise ConfigurationError, "Node '#{node_name}' must be a hash"
          end

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
end
