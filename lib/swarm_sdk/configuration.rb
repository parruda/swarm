# frozen_string_literal: true

module SwarmSDK
  # Configuration facade that delegates to Parser and Translator
  #
  # This class maintains the public API while internally delegating to:
  # - Configuration::Parser - YAML parsing, validation, and normalization
  # - Configuration::Translator - Translation to Swarm/Workflow DSL builders
  #
  # ## Public API (unchanged)
  # - Configuration.load_file(path) - Load from file
  # - Configuration.new(yaml_content, base_dir:) - Load from string
  # - config.load_and_validate - Parse and validate
  # - config.to_swarm(allow_filesystem_tools:) - Convert to Swarm/Workflow
  # - config.agent_names - Get list of agent names
  # - config.connections_for(agent_name) - Get delegation targets
  #
  # ## Architecture
  # The facade pattern keeps backward compatibility while separating concerns:
  # - Parser handles all YAML parsing and validation logic
  # - Translator handles all DSL builder translation logic
  # - Configuration delegates to both, exposing parsed data via attr_readers
  class Configuration
    attr_reader :config_type,
      :swarm_name,
      :swarm_id,
      :lead_agent,
      :start_node,
      :agents,
      :all_agents_config,
      :swarm_hooks,
      :all_agents_hooks,
      :scratchpad_enabled,
      :nodes,
      :external_swarms

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
      @parser = nil
      @translator = nil
    end

    # Parse and validate YAML configuration
    #
    # Delegates to Parser for all parsing logic, then syncs parsed data
    # to instance variables for backward compatibility.
    #
    # @return [self]
    def load_and_validate
      @parser = Parser.new(@yaml_content, base_dir: @base_dir)
      @parser.parse

      # Sync parsed data to instance variables for backward compatibility
      sync_from_parser

      self
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
    # Delegates to Translator for all DSL translation logic.
    #
    # @param allow_filesystem_tools [Boolean, nil] Whether to allow filesystem tools (nil uses global setting)
    # @return [Swarm, Workflow] Configured swarm or workflow
    def to_swarm(allow_filesystem_tools: nil)
      raise ConfigurationError, "Configuration not loaded. Call load_and_validate first." unless @parser

      @translator = Translator.new(@parser)
      @translator.to_swarm(allow_filesystem_tools: allow_filesystem_tools)
    end

    private

    # Sync parsed data from Parser to instance variables
    #
    # This maintains backward compatibility with code that accesses
    # @config_type, @agents, etc. directly via attr_readers.
    def sync_from_parser
      @config_type = @parser.config_type
      @swarm_name = @parser.swarm_name
      @swarm_id = @parser.swarm_id
      @lead_agent = @parser.lead_agent
      @start_node = @parser.start_node
      @agents = @parser.agents
      @all_agents_config = @parser.all_agents_config
      @swarm_hooks = @parser.swarm_hooks
      @all_agents_hooks = @parser.all_agents_hooks
      @external_swarms = @parser.external_swarms
      @nodes = @parser.nodes
      @scratchpad_enabled = @parser.scratchpad_mode # NOTE: attr_reader says scratchpad_enabled
    end
  end
end
