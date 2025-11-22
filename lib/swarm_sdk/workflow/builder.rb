# frozen_string_literal: true

module SwarmSDK
  class Workflow
    # Builder provides DSL for building multi-node workflows
    # This is the top-level builder accessed via SwarmSDK.workflow
    #
    # The DSL enables:
    # - Node-based workflow configuration
    # - Agent delegation per node
    # - Input/output transformers for data flow
    # - Context preservation across nodes
    #
    # @example Multi-stage workflow
    #   workflow = SwarmSDK.workflow do
    #     name "Build Pipeline"
    #     start_node :planning
    #
    #     agent :architect do
    #       model "gpt-5"
    #       prompt "You design systems"
    #     end
    #
    #     agent :coder do
    #       model "gpt-4"
    #       prompt "You implement code"
    #     end
    #
    #     node :planning do
    #       agent(:architect)
    #     end
    #
    #     node :implementation do
    #       agent(:coder)
    #       depends_on :planning
    #     end
    #   end
    #
    #   workflow.execute("Build auth system")
    class Builder < Builders::BaseBuilder
      # Main entry point for DSL
      #
      # @example
      #   workflow = SwarmSDK.workflow do
      #     name "Pipeline"
      #     start_node :planning
      #     node(:planning) { agent(:architect) }
      #   end
      class << self
        def build(allow_filesystem_tools: nil, &block)
          builder = new(allow_filesystem_tools: allow_filesystem_tools)
          builder.instance_eval(&block)
          builder.build_swarm
        end
      end

      def initialize(allow_filesystem_tools: nil)
        super
        @nodes = {}
        @start_node = nil
      end

      # Define a node (mini-swarm execution stage)
      #
      # Nodes enable multi-stage workflows where different agent teams
      # collaborate in sequence. Each node is an independent swarm execution.
      #
      # @param name [Symbol] Node name
      # @yield Block for node configuration
      # @return [void]
      #
      # @example Solo agent node
      #   node :planning do
      #     agent(:architect)
      #   end
      #
      # @example Multi-agent node with delegation
      #   node :implementation do
      #     agent(:backend).delegates_to(:tester, :database)
      #     agent(:tester).delegates_to(:database)
      #     agent(:database)
      #     depends_on :planning
      #   end
      def node(name, &block)
        builder = Workflow::NodeBuilder.new(name)
        builder.instance_eval(&block)
        @nodes[name] = builder
      end

      # Set the starting node for workflow execution
      #
      # Required when nodes are defined. Specifies which node to execute first.
      #
      # @param name [Symbol] Name of starting node
      # @return [void]
      #
      # @example
      #   start_node :planning
      def start_node(name)
        @start_node = name.to_sym
      end

      # Build the actual Workflow instance
      def build_swarm # Returns Workflow despite method name
        raise ConfigurationError, "Workflow name not set. Use: name 'My Workflow'" unless @swarm_name
        raise ConfigurationError, "No nodes defined. Use: node :name { ... }" if @nodes.empty?
        raise ConfigurationError, "start_node not set. Use: start_node :name" unless @start_node

        # Validate filesystem tools BEFORE building
        validate_all_agents_filesystem_tools if @all_agents_config
        validate_agent_filesystem_tools

        build_workflow
      end

      private

      # Build a node-based workflow
      #
      # @return [Workflow] Configured workflow instance
      def build_workflow
        # Resolve any missing agents from global registry before building definitions
        resolve_missing_agents_from_registry

        # Build agent definitions
        agent_definitions = build_agent_definitions

        # Create workflow
        workflow = Workflow.new(
          swarm_name: @swarm_name,
          swarm_id: @swarm_id,
          agent_definitions: agent_definitions,
          nodes: @nodes,
          start_node: @start_node,
          scratchpad: @scratchpad,
          allow_filesystem_tools: @allow_filesystem_tools,
        )

        # Pass swarm registry config to workflow if external swarms registered
        workflow.swarm_registry_config = @swarm_registry_config if @swarm_registry_config.any?

        workflow
      end

      # Resolve agents referenced in nodes that aren't defined at workflow level
      #
      # For each agent referenced in a node but not defined with `agent :name do ... end`,
      # checks the global AgentRegistry and loads the agent if found.
      #
      # This allows workflows to reference globally registered agents without
      # explicitly re-declaring them at the workflow level.
      #
      # @return [void]
      # @raise [ConfigurationError] If agent not found in workflow or registry
      def resolve_missing_agents_from_registry
        # Collect all agents referenced in nodes
        referenced_agents = collect_referenced_agents

        # Find agents that aren't defined at workflow level
        defined_agents = @agents.keys
        missing_agents = referenced_agents - defined_agents

        # Try to resolve each missing agent from the global registry
        missing_agents.each do |agent_name|
          if AgentRegistry.registered?(agent_name)
            # Load from registry (uses same method as BaseBuilder)
            load_agent_from_registry(agent_name)
          else
            raise ConfigurationError,
              "Agent '#{agent_name}' referenced in node but not found. " \
                "Either define at workflow level with `agent :#{agent_name} do ... end` " \
                "or register globally with `SwarmSDK.agent :#{agent_name} do ... end`"
          end
        end
      end

      # Collect all agent names referenced across all nodes
      #
      # Includes both directly referenced agents and delegation targets.
      #
      # @return [Array<Symbol>] Unique agent names referenced in nodes
      def collect_referenced_agents
        @nodes.values.flat_map do |node_builder|
          # Collect both direct agents and their delegation targets
          node_builder.agent_configs.flat_map do |config|
            [config[:agent]] + Array(config[:delegates_to])
          end
        end.uniq
      end
    end
  end
end
