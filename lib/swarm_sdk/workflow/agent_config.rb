# frozen_string_literal: true

module SwarmSDK
  class Workflow
    # AgentConfig provides fluent API for configuring agents within a node
    #
    # This class enables the chainable syntax:
    #   agent(:backend).delegates_to(:tester, :database)
    #   agent(:backend, reset_context: false)  # Preserve context across nodes
    #   agent(:backend).tools(:Read, :Edit)    # Override tools for this node
    #
    # @example Basic delegation
    #   agent(:backend).delegates_to(:tester)
    #
    # @example No delegation (solo agent)
    #   agent(:planner)
    #
    # @example Preserve agent context
    #   agent(:architect, reset_context: false)
    #
    # @example Override tools for this node
    #   agent(:backend).tools(:Read, :Think)
    #
    # @example Combine delegation and tool override
    #   agent(:backend).delegates_to(:tester).tools(:Read, :Edit, :Write)
    class AgentConfig
      attr_reader :agent_name

      def initialize(agent_name, node_builder, reset_context: true)
        @agent_name = agent_name
        @node_builder = node_builder
        @delegates_to = []
        @reset_context = reset_context
        @tools = nil # nil means use global agent definition tools
        @finalized = false
      end

      # Set delegation targets for this agent
      #
      # @param agent_names [Array<Symbol>] Names of agents to delegate to
      # @return [self] For method chaining
      def delegates_to(*agent_names)
        @delegates_to = agent_names.map(&:to_sym)
        update_registration
        self
      end

      # Override tools for this agent in this node
      #
      # @param tool_names [Array<Symbol>] Tool names to use (overrides global agent definition)
      # @return [self] For method chaining
      #
      # @example
      #   agent(:backend).tools(:Read, :Edit)
      def tools(*tool_names)
        @tools = tool_names.map(&:to_sym)
        update_registration
        self
      end

      # Update agent registration (called after each fluent method)
      #
      # Always updates the registration with current state.
      # This allows chaining: .delegates_to(...).tools(...)
      #
      # @return [void]
      def update_registration
        @node_builder.register_agent(@agent_name, @delegates_to, @reset_context, @tools)
      end

      # Finalize agent configuration (backward compatibility)
      #
      # @return [void]
      def finalize
        update_registration
      end
    end
  end
end
