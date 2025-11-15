# frozen_string_literal: true

module SwarmSDK
  # Workflow executes a multi-node workflow
  #
  # Each node represents a mini-swarm execution stage. The workflow:
  # - Builds execution order from node dependencies (topological sort)
  # - Creates a separate swarm instance for each node
  # - Passes output from one node as input to dependent nodes
  # - Supports input/output transformers for data flow customization
  #
  # @example
  #   workflow = Workflow.new(
  #     swarm_name: "Dev Team",
  #     agent_definitions: { backend: def1, tester: def2 },
  #     nodes: { planning: node1, implementation: node2 },
  #     start_node: :planning
  #   )
  #   result = workflow.execute("Build auth system")
  class Workflow
    attr_reader :swarm_name, :nodes, :start_node, :agent_definitions, :scratchpad
    attr_reader :agents, :delegation_instances, :swarm_id, :parent_swarm_id, :mcp_clients
    attr_reader :execution_order
    attr_writer :swarm_id, :config_for_hooks
    attr_accessor :swarm_registry_config, :original_prompt

    def initialize(swarm_name:, agent_definitions:, nodes:, start_node:, swarm_id: nil, scratchpad: :enabled, allow_filesystem_tools: nil)
      @swarm_name = swarm_name
      @swarm_id = swarm_id || generate_swarm_id(swarm_name)
      @parent_swarm_id = nil # Workflows don't have parent swarms
      @agent_definitions = agent_definitions
      @nodes = nodes
      @start_node = start_node
      @scratchpad = normalize_scratchpad_mode(scratchpad)
      @allow_filesystem_tools = allow_filesystem_tools
      @swarm_registry_config = [] # External swarms config (if using composable swarms)

      # Simplified structure (matches Swarm)
      @agents = {}                    # Cached primary agents from nodes
      @delegation_instances = {}      # Cached delegation instances from nodes

      # MCP clients per agent (for cleanup compatibility)
      @mcp_clients = Hash.new { |h, k| h[k] = [] }

      # Initialize scratchpad storage based on mode
      case @scratchpad
      when :enabled
        # Enabled mode: single scratchpad shared across all nodes
        @shared_scratchpad_storage = Tools::Stores::ScratchpadStorage.new
        @node_scratchpads = nil
      when :per_node
        # Per-node mode: separate scratchpad per node (lazy initialized)
        @shared_scratchpad_storage = nil
        @node_scratchpads = {}
      when :disabled
        # Disabled: no storage at all
        @shared_scratchpad_storage = nil
        @node_scratchpads = nil
      end

      validate!
      @execution_order = build_execution_order
    end

    # Provide name method for interface compatibility
    def name
      @swarm_name
    end

    # Implement Snapshotable interface
    def primary_agents
      @agents
    end

    def delegation_instances_hash
      @delegation_instances
    end

    # No-op for Swarm compatibility (Workflow doesn't track first message)
    def first_message_sent?
      false
    end

    # Get scratchpad storage for a specific node
    #
    # Returns the appropriate scratchpad based on mode:
    # - :enabled - returns the shared scratchpad (same for all nodes)
    # - :per_node - returns node-specific scratchpad (lazy initialized)
    # - :disabled - returns nil
    #
    # @param node_name [Symbol] Node name
    # @return [Tools::Stores::ScratchpadStorage, nil] Scratchpad instance or nil if disabled
    def scratchpad_for(node_name)
      case @scratchpad
      when :enabled
        @shared_scratchpad_storage
      when :per_node
        # Lazy initialization per node
        @node_scratchpads[node_name] ||= Tools::Stores::ScratchpadStorage.new
      when :disabled
        nil
      end
    end

    # Get all scratchpad storages (for snapshot/restore)
    #
    # @return [Hash] { :shared => scratchpad } or { node_name => scratchpad }
    def all_scratchpads
      case @scratchpad
      when :enabled
        { shared: @shared_scratchpad_storage }
      when :per_node
        @node_scratchpads.dup
      when :disabled
        {}
      end
    end

    # Check if scratchpad is enabled
    #
    # @return [Boolean]
    def scratchpad_enabled?
      @scratchpad != :disabled
    end

    # Check if scratchpad is shared between nodes (enabled mode)
    #
    # @return [Boolean]
    def shared_scratchpad?
      @scratchpad == :enabled
    end

    # Check if scratchpad is per-node
    #
    # @return [Boolean]
    def per_node_scratchpad?
      @scratchpad == :per_node
    end

    # Backward compatibility accessor
    #
    # @return [Tools::Stores::ScratchpadStorage, nil]
    def shared_scratchpad_storage
      if @scratchpad == :per_node
        RubyLLM.logger.warn("Workflow: Accessing shared_scratchpad_storage in per-node mode. Use scratchpad_for(node_name) instead.")
      end
      @shared_scratchpad_storage
    end

    # Return the lead agent of the start node for CLI compatibility
    #
    # @return [Symbol] Lead agent of the start node
    def lead_agent
      @nodes[@start_node].lead_agent
    end

    # Execute the node workflow
    #
    # Executes nodes in topological order, passing output from each node
    # to its dependents. Supports streaming logs if block given.
    #
    # @param prompt [String] Initial prompt for the workflow
    # @yield [Hash] Log entry if block given (for streaming)
    # @return [Result] Final result from last node execution
    def execute(prompt, &block)
      Executor.new(self).run(prompt, &block)
    end

    # Create snapshot of current workflow state
    #
    # Returns a Snapshot object containing agent conversations, context state,
    # and scratchpad data from all nodes that have been executed. The snapshot
    # captures the state of agents in the agent_instance_cache (both primary and
    # delegation instances), as well as scratchpad storage.
    #
    # Configuration (agent definitions, nodes, transformers) stays in your code
    # and is NOT included in snapshots.
    #
    # Scratchpad behavior depends on scratchpad mode:
    # - :enabled (default): single scratchpad shared across all nodes
    # - :per_node: separate scratchpad per node
    # - :disabled: no scratchpad data
    #
    # @return [Snapshot] Snapshot object with convenient serialization methods
    #
    # @example Save snapshot to JSON file
    #   workflow = Workflow.new(...)
    #   workflow.execute("Build feature")
    #   snapshot = workflow.snapshot
    #   snapshot.write_to_file("workflow_session.json")
    def snapshot
      StateSnapshot.new(self).snapshot
    end

    # Restore workflow state from snapshot
    #
    # Accepts a Snapshot object, hash, or JSON string. Validates compatibility
    # between snapshot and current workflow configuration. Restores agent
    # conversations that exist in the cached agents.
    #
    # The workflow must be created with the SAME configuration (agent definitions,
    # nodes) as when the snapshot was created. Only conversation state is restored.
    #
    # For agents with reset_context: false, restored conversations will be injected
    # during node execution. Agents not in cache yet will be skipped (they haven't
    # been used yet, so there's nothing to restore).
    #
    # @param snapshot [Snapshot, Hash, String] Snapshot object, hash, or JSON string
    # @return [RestoreResult] Result with warnings about skipped agents
    #
    # @example Restore from Snapshot object
    #   workflow = Workflow.new(...)  # Same config as snapshot
    #   snapshot = Snapshot.from_file("workflow_session.json")
    #   result = workflow.restore(snapshot)
    #   if result.success?
    #     puts "All agents restored"
    #   else
    #     puts result.summary
    #   end
    #
    # Restore workflow state from snapshot
    #
    # By default, uses current system prompts from agent definitions (YAML + SDK defaults + plugin injections).
    # Set preserve_system_prompts: true to use historical prompts from snapshot.
    #
    # @param snapshot [Snapshot, Hash, String] Snapshot object, hash, or JSON string
    # @param preserve_system_prompts [Boolean] Use historical system prompts instead of current config (default: false)
    # @return [RestoreResult] Result with warnings about partial restores
    def restore(snapshot, preserve_system_prompts: false)
      StateRestorer.new(self, snapshot, preserve_system_prompts: preserve_system_prompts).restore
    end

    # Build a swarm instance for a specific node
    #
    # Creates a new Swarm with only the agents specified in the node,
    # configured with the node's delegation topology.
    #
    # For agents with reset_context: false, injects cached instances
    # to preserve conversation history across nodes.
    #
    # Scratchpad behavior depends on mode:
    # - :enabled - all nodes use the same scratchpad instance
    # - :per_node - each node gets its own scratchpad instance
    # - :disabled - no scratchpad
    #
    # @param node [Workflow::NodeBuilder] Node configuration
    # @return [Swarm] Configured swarm instance
    def build_swarm_for_node(node)
      # Build hierarchical swarm_id if parent has one (nil auto-generates)
      node_swarm_id = @swarm_id ? "#{@swarm_id}/node:#{node.name}" : nil

      swarm = Swarm.new(
        name: "#{@swarm_name}:#{node.name}",
        swarm_id: node_swarm_id,
        parent_swarm_id: @swarm_id,
        scratchpad: scratchpad_for(node.name),
        scratchpad_mode: :enabled, # Mini-swarms always use enabled (scratchpad instance passed in)
        allow_filesystem_tools: @allow_filesystem_tools,
      )

      # Setup swarm registry if external swarms are registered
      if @swarm_registry_config&.any?
        registry = SwarmRegistry.new(parent_swarm_id: node_swarm_id || swarm.swarm_id)
        @swarm_registry_config.each do |reg|
          registry.register(reg[:name], source: reg[:source], keep_context: reg[:keep_context])
        end
        swarm.swarm_registry = registry
      end

      # Add each agent specified in this node
      node.agent_configs.each do |config|
        agent_name = config[:agent]
        delegates_to = config[:delegates_to]
        tools_override = config[:tools]

        # Get global agent definition
        agent_def = @agent_definitions[agent_name]

        # Clone definition with node-specific overrides
        node_specific_def = clone_agent_for_node(agent_def, delegates_to, tools_override)

        swarm.add_agent(node_specific_def)
      end

      # Set lead agent
      swarm.lead = node.lead_agent

      # Inject cached agent instances for context preservation
      inject_cached_agents(swarm, node)

      swarm
    end

    # Cache agent instances from a swarm for potential reuse
    #
    # Only caches agents that have reset_context: false in this node.
    # This allows preserving conversation history across nodes.
    #
    # @param swarm [Swarm] Swarm instance that just executed
    # @param node [Workflow::Builder] Node configuration
    # @return [void]
    def cache_agent_instances(swarm, node)
      return unless swarm.agents

      node.agent_configs.each do |config|
        agent_name = config[:agent]
        reset_context = config[:reset_context]

        # Only cache if reset_context: false
        next if reset_context

        # Cache primary agent
        agent_instance = swarm.agents[agent_name]
        @agents[agent_name] = agent_instance if agent_instance

        # Cache delegation instances atomically (together with primary)
        agent_def = @agent_definitions[agent_name]
        agent_def.delegates_to.each do |delegate_name|
          delegation_key = "#{delegate_name}@#{agent_name}"
          delegation_instance = swarm.delegation_instances[delegation_key]

          if delegation_instance
            @delegation_instances[delegation_key] = delegation_instance
          end
        end
      end
    end

    private

    # Generate a unique execution ID for workflow
    #
    # Creates an execution ID that uniquely identifies a single workflow.execute() call.
    # Format: "exec_workflow_{random_hex}"
    #
    # @return [String] Generated execution ID (e.g., "exec_workflow_a3f2b1c8")
    def generate_swarm_id(name)
      sanitized = name.to_s.gsub(/[^a-z0-9_-]/i, "_").downcase
      "#{sanitized}_#{SecureRandom.hex(4)}"
    end

    # Validate workflow configuration
    #
    # @return [void]
    # @raise [ConfigurationError] If configuration is invalid
    def validate!
      # Validate start_node exists
      unless @nodes.key?(@start_node)
        raise ConfigurationError,
          "start_node '#{@start_node}' not found. Available nodes: #{@nodes.keys.join(", ")}"
      end

      # Validate all nodes
      @nodes.each_value(&:validate!)

      # Validate node dependencies reference existing nodes
      @nodes.each do |node_name, node|
        node.dependencies.each do |dep|
          unless @nodes.key?(dep)
            raise ConfigurationError,
              "Node '#{node_name}' depends on unknown node '#{dep}'"
          end
        end
      end

      # Validate all agents referenced in nodes exist (skip agent-less nodes)
      @nodes.each do |node_name, node|
        next if node.agent_less? # Skip validation for agent-less nodes

        node.agent_configs.each do |config|
          agent_name = config[:agent]
          unless @agent_definitions.key?(agent_name)
            raise ConfigurationError,
              "Node '#{node_name}' references undefined agent '#{agent_name}'"
          end

          # Validate delegation targets exist
          config[:delegates_to].each do |delegate|
            unless @agent_definitions.key?(delegate)
              raise ConfigurationError,
                "Node '#{node_name}' agent '#{agent_name}' delegates to undefined agent '#{delegate}'"
            end
          end
        end
      end
    end

    # Clone an agent definition with node-specific overrides
    #
    # Allows overriding delegation and tools per node. This enables:
    # - Different delegation topology per node
    # - Different tool sets per workflow stage
    #
    # @param agent_def [Agent::Definition] Original definition
    # @param delegates_to [Array<Symbol>] New delegation targets
    # @param tools [Array<Symbol>, nil] Tool override (nil = use global agent definition)
    # @return [Agent::Definition] Cloned definition with overrides
    def clone_agent_for_node(agent_def, delegates_to, tools)
      config = agent_def.to_h
      config[:delegates_to] = delegates_to
      config[:tools] = tools if tools # Only override if explicitly set
      Agent::Definition.new(agent_def.name, config)
    end

    # Build execution order using topological sort (Kahn's algorithm)
    #
    # Processes all nodes in dependency order, starting from start_node.
    # Ensures all nodes are reachable from start_node.
    #
    # @return [Array<Symbol>] Ordered list of node names
    # @raise [CircularDependencyError] If circular dependency detected
    def build_execution_order
      # Build in-degree map and adjacency list
      in_degree = {}
      adjacency = Hash.new { |h, k| h[k] = [] }

      @nodes.each do |node_name, node|
        in_degree[node_name] = node.dependencies.size
        node.dependencies.each do |dep|
          adjacency[dep] << node_name
        end
      end

      # Start with nodes that have no dependencies
      queue = in_degree.select { |_, degree| degree == 0 }.keys
      order = []

      while queue.any?
        # Process nodes with all dependencies satisfied
        node_name = queue.shift
        order << node_name

        # Reduce in-degree for dependent nodes
        adjacency[node_name].each do |dependent|
          in_degree[dependent] -= 1
          queue << dependent if in_degree[dependent] == 0
        end
      end

      # Check for circular dependencies
      if order.size < @nodes.size
        unprocessed = @nodes.keys - order
        raise CircularDependencyError,
          "Circular dependency detected. Unprocessed nodes: #{unprocessed.join(", ")}. " \
            "Use goto_node in transformers to create loops instead of circular depends_on."
      end

      # Verify start_node is in the execution order
      unless order.include?(@start_node)
        raise ConfigurationError,
          "start_node '#{@start_node}' is not reachable in the dependency graph"
      end

      # Verify start_node is actually first (or rearrange to make it first)
      # This ensures we start from the declared start_node
      start_index = order.index(@start_node)
      if start_index && start_index > 0
        # start_node has dependencies - this violates the assumption
        raise ConfigurationError,
          "start_node '#{@start_node}' has dependencies: #{@nodes[@start_node].dependencies.join(", ")}. " \
            "start_node must have no dependencies."
      end

      order
    end

    # Inject cached agent instances into a swarm
    #
    # For agents with reset_context: false, reuses cached instances to preserve context.
    # Forces agent initialization first (by accessing .agents), then swaps in cached instances.
    #
    # @param swarm [Swarm] Swarm instance to inject into
    # @param node [Workflow::Builder] Node configuration
    # @return [void]
    def inject_cached_agents(swarm, node)
      # Check if any agents need context preservation
      has_preserved = node.agent_configs.any? do |c|
        !c[:reset_context] && (
          @agents[c[:agent]] ||
          has_cached_delegations_for?(c[:agent])
        )
      end
      return unless has_preserved

      # Force initialization FIRST
      # Without this, @agents will be replaced by initialize_all, losing our injected instances
      swarm.agent(node.agent_configs.first[:agent]) # Triggers lazy init

      # Now safely inject cached instances
      agents_hash = swarm.agents
      delegation_hash = swarm.delegation_instances

      # Inject cached PRIMARY agents
      node.agent_configs.each do |config|
        agent_name = config[:agent]
        next if config[:reset_context]

        cached_agent = @agents[agent_name]
        next unless cached_agent

        # Replace freshly initialized agent with cached instance
        agents_hash[agent_name] = cached_agent
      end

      # Inject cached DELEGATION instances (atomic with primary)
      node.agent_configs.each do |config|
        agent_name = config[:agent]
        next if config[:reset_context]

        agent_def = @agent_definitions[agent_name]

        agent_def.delegates_to.each do |delegate_name|
          delegation_key = "#{delegate_name}@#{agent_name}"
          cached_delegation = @delegation_instances[delegation_key]
          next unless cached_delegation

          # Replace freshly initialized delegation instance
          # Tool references intact - atomic caching preserves object graph
          delegation_hash[delegation_key] = cached_delegation
        end
      end
    end

    def has_cached_delegations_for?(agent_name)
      agent_def = @agent_definitions[agent_name]
      agent_def.delegates_to.any? do |delegate_name|
        delegation_key = "#{delegate_name}@#{agent_name}"
        @delegation_instances[delegation_key]
      end
    end

    # Normalize scratchpad mode parameter
    #
    # Accepts symbols: :enabled, :per_node, or :disabled
    #
    # @param value [Symbol, String] Scratchpad mode (strings from YAML converted to symbols)
    # @return [Symbol] Normalized mode (:enabled, :per_node, or :disabled)
    # @raise [ArgumentError] If value is invalid
    def normalize_scratchpad_mode(value)
      # Convert strings from YAML to symbols
      value = value.to_sym if value.is_a?(String)

      case value
      when :enabled, :per_node, :disabled
        value
      else
        raise ArgumentError,
          "Invalid scratchpad mode: #{value.inspect}. Use :enabled, :per_node, or :disabled"
      end
    end
  end
end
