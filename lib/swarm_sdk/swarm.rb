# frozen_string_literal: true

module SwarmSDK
  # Swarm orchestrates multiple AI agents with shared rate limiting and coordination.
  #
  # This is the main user-facing API for SwarmSDK. Users create swarms using:
  # - Ruby DSL: SwarmSDK.build { ... } (Recommended)
  # - YAML String: SwarmSDK.load(yaml, base_dir:)
  # - YAML File: SwarmSDK.load_file(path)
  # - Direct API: Swarm.new + add_agent (Advanced)
  #
  # ## Ruby DSL (Recommended)
  #
  #   swarm = SwarmSDK.build do
  #     name "Development Team"
  #     lead :backend
  #
  #     agent :backend do
  #       model "gpt-5"
  #       description "Backend developer"
  #       prompt "You build APIs"
  #       tools :Read, :Edit, :Bash
  #     end
  #   end
  #   result = swarm.execute("Build authentication")
  #
  # ## YAML String API
  #
  #   yaml = File.read("swarm.yml")
  #   swarm = SwarmSDK.load(yaml, base_dir: "/path/to/project")
  #   result = swarm.execute("Build authentication")
  #
  # ## YAML File API (Convenience)
  #
  #   swarm = SwarmSDK.load_file("swarm.yml")
  #   result = swarm.execute("Build authentication")
  #
  # ## Direct API (Advanced)
  #
  #   swarm = Swarm.new(name: "Development Team")
  #
  #   backend_agent = Agent::Definition.new(:backend, {
  #     description: "Backend developer",
  #     model: "gpt-5",
  #     system_prompt: "You build APIs and databases...",
  #     tools: [:Read, :Edit, :Bash],
  #     delegates_to: [:database]
  #   })
  #   swarm.add_agent(backend_agent)
  #
  #   swarm.lead = :backend
  #   result = swarm.execute("Build authentication")
  #
  # ## Architecture
  #
  # All APIs converge on Agent::Definition for validation.
  # Swarm delegates to specialized concerns:
  # - Agent::Definition: Validates configuration, builds system prompts
  # - AgentInitializer: Complex 5-pass agent setup
  # - ToolConfigurator: Tool creation and permissions (via AgentInitializer)
  # - McpConfigurator: MCP client management (via AgentInitializer)
  #
  class Swarm
    include Concerns::Snapshotable
    include Concerns::Validatable
    include Concerns::Cleanupable
    include LoggingCallbacks
    include HookTriggers

    # Backward compatibility aliases - use Defaults module for new code
    DEFAULT_MCP_LOG_LEVEL = Defaults::Logging::MCP_LOG_LEVEL

    # Default tools available to all agents
    DEFAULT_TOOLS = ToolConfigurator::DEFAULT_TOOLS

    attr_reader :name, :agents, :lead_agent, :mcp_clients, :delegation_instances, :agent_definitions, :swarm_id, :parent_swarm_id, :swarm_registry, :scratchpad_storage, :allow_filesystem_tools, :hook_registry, :global_semaphore, :plugin_storages, :config_for_hooks, :observer_configs
    attr_accessor :delegation_call_stack

    # Check if scratchpad tools are enabled
    #
    # @return [Boolean]
    def scratchpad_enabled?
      @scratchpad_mode == :enabled
    end
    attr_writer :config_for_hooks

    # Check if first message has been sent (for system reminder injection)
    #
    # @return [Boolean]
    def first_message_sent?
      @first_message_sent
    end

    # Set first message sent flag (used by snapshot/restore)
    #
    # @param value [Boolean] New value
    # @return [void]
    attr_writer :first_message_sent

    # Class-level MCP log level configuration
    @mcp_log_level = DEFAULT_MCP_LOG_LEVEL
    @mcp_logging_configured = false

    class << self
      attr_accessor :mcp_log_level

      # Configure MCP client logging globally
      #
      # This should be called before creating any swarms that use MCP servers.
      # The configuration is global and affects all MCP clients.
      #
      # @param level [Integer] Log level (Logger::DEBUG, Logger::INFO, Logger::WARN, Logger::ERROR, Logger::FATAL)
      # @return [void]
      def configure_mcp_logging(level = DEFAULT_MCP_LOG_LEVEL)
        @mcp_log_level = level
        apply_mcp_logging_configuration
      end

      # Apply MCP logging configuration to RubyLLM::MCP
      #
      # @return [void]
      def apply_mcp_logging_configuration
        return if @mcp_logging_configured

        RubyLLM::MCP.configure do |config|
          config.log_level = @mcp_log_level
        end

        @mcp_logging_configured = true
      end
    end

    # Initialize a new Swarm
    #
    # @param name [String] Human-readable swarm name
    # @param swarm_id [String, nil] Optional swarm ID (auto-generated if not provided)
    # @param parent_swarm_id [String, nil] Optional parent swarm ID (nil for root swarms)
    # @param global_concurrency [Integer] Max concurrent LLM calls across entire swarm
    # @param default_local_concurrency [Integer] Default max concurrent tool calls per agent
    # @param scratchpad [Tools::Stores::Scratchpad, nil] Optional scratchpad instance (for testing/internal use)
    # @param scratchpad_mode [Symbol, String] Scratchpad mode (:enabled or :disabled). :per_node not allowed for non-node swarms.
    # @param allow_filesystem_tools [Boolean, nil] Whether to allow filesystem tools (nil uses global setting)
    def initialize(name:, swarm_id: nil, parent_swarm_id: nil, global_concurrency: Defaults::Concurrency::GLOBAL_LIMIT, default_local_concurrency: Defaults::Concurrency::LOCAL_LIMIT, scratchpad: nil, scratchpad_mode: :enabled, allow_filesystem_tools: nil)
      @name = name
      @swarm_id = swarm_id || generate_swarm_id(name)
      @parent_swarm_id = parent_swarm_id
      @global_concurrency = global_concurrency
      @default_local_concurrency = default_local_concurrency

      # Handle scratchpad_mode parameter
      # For Swarm: :enabled or :disabled (not :per_node - that's for nodes)
      @scratchpad_mode = validate_swarm_scratchpad_mode(scratchpad_mode)

      # Resolve allow_filesystem_tools with priority:
      # 1. Explicit parameter (if not nil)
      # 2. Global settings
      @allow_filesystem_tools = if allow_filesystem_tools.nil?
        SwarmSDK.settings.allow_filesystem_tools
      else
        allow_filesystem_tools
      end

      # Swarm registry for managing sub-swarms (initialized later if needed)
      @swarm_registry = nil

      # Delegation call stack for circular dependency detection
      @delegation_call_stack = []

      # Shared semaphore for all agents
      @global_semaphore = Async::Semaphore.new(@global_concurrency)

      # Shared scratchpad storage for all agents (volatile)
      # Use provided scratchpad storage (for testing) or create volatile one based on mode
      @scratchpad_storage = if scratchpad
        scratchpad # Testing/internal use - explicit instance provided
      elsif @scratchpad_mode == :enabled
        Tools::Stores::ScratchpadStorage.new
      end

      # Per-agent plugin storages (persistent)
      # Format: { plugin_name => { agent_name => storage } }
      # Will be populated when agents are initialized
      @plugin_storages = {}

      # Hook registry for named hooks and swarm defaults
      @hook_registry = Hooks::Registry.new

      # Register default logging hooks
      register_default_logging_callbacks

      # Agent definitions and instances
      @agent_definitions = {}
      @agents = {}
      @delegation_instances = {} # { "delegate@delegator" => Agent::Chat }
      @agents_initialized = false
      @agent_contexts = {}

      # MCP clients per agent (for cleanup)
      @mcp_clients = Hash.new { |h, k| h[k] = [] }

      @lead_agent = nil

      # Track if first message has been sent
      @first_message_sent = false

      # Track if agent_start events have been emitted
      # This prevents duplicate emissions and ensures events are emitted when logging is ready
      @agent_start_events_emitted = false

      # Observer agent configurations
      @observer_configs = []
      @observer_manager = nil
    end

    # Add an agent to the swarm
    #
    # Accepts only Agent::Definition objects. This ensures all validation
    # happens in a single place (Agent::Definition) and keeps the API clean.
    #
    # If the definition doesn't specify max_concurrent_tools, the swarm's
    # default_local_concurrency is applied.
    #
    # @param definition [Agent::Definition] Fully configured agent definition
    # @return [self]
    #
    # @example
    #   definition = Agent::Definition.new(:backend, {
    #     description: "Backend developer",
    #     model: "gpt-5",
    #     system_prompt: "You build APIs"
    #   })
    #   swarm.add_agent(definition)
    def add_agent(definition)
      unless definition.is_a?(Agent::Definition)
        raise ArgumentError, "Expected Agent::Definition, got #{definition.class}"
      end

      name = definition.name
      raise ConfigurationError, "Agent '#{name}' already exists" if @agent_definitions.key?(name)

      # Apply swarm's default_local_concurrency if max_concurrent_tools not set
      definition.max_concurrent_tools = @default_local_concurrency if definition.max_concurrent_tools.nil?

      @agent_definitions[name] = definition
      self
    end

    # Set the lead agent (entry point for swarm execution)
    #
    # @param name [Symbol, String] Name of agent to make lead
    # @return [self]
    def lead=(name)
      name = name.to_sym

      unless @agent_definitions.key?(name)
        raise ConfigurationError, "Cannot set lead: agent '#{name}' not found"
      end

      @lead_agent = name
    end

    # Execute a task using the lead agent
    #
    # The lead agent can delegate to other agents via tool calls,
    # and the entire swarm coordinates with shared rate limiting.
    # Supports reprompting via swarm_stop hooks.
    #
    # By default, this method blocks until execution completes. Set wait: false
    # to return an Async::Task immediately, enabling cancellation via task.stop.
    #
    # @param prompt [String] Task to execute
    # @param wait [Boolean] If true (default), blocks until execution completes.
    #   If false, returns Async::Task immediately for non-blocking execution.
    # @yield [Hash] Log entry if block given (for streaming)
    # @return [Result, Async::Task] Result if wait: true, Async::Task if wait: false
    #
    # @example Blocking execution (default)
    #   result = swarm.execute("Build auth")
    #   puts result.content
    #
    # @example Non-blocking execution with cancellation
    #   task = swarm.execute("Build auth", wait: false) { |event| puts event }
    #   # ... do other work ...
    #   task.stop  # Cancel anytime
    #   result = task.wait  # Returns nil for cancelled tasks
    def execute(prompt, wait: true, &block)
      raise ConfigurationError, "No lead agent set. Set lead= first." unless @lead_agent

      logs = []
      current_prompt = prompt
      has_logging = block_given?

      # Save original Fiber storage for restoration (preserves parent context for nested swarms)
      original_fiber_storage = {
        execution_id: Fiber[:execution_id],
        swarm_id: Fiber[:swarm_id],
        parent_swarm_id: Fiber[:parent_swarm_id],
      }

      # Set fiber-local execution context
      # Use ||= to inherit parent's execution_id if one exists (for mini-swarms)
      Fiber[:execution_id] ||= generate_execution_id
      Fiber[:swarm_id] = @swarm_id
      Fiber[:parent_swarm_id] = @parent_swarm_id

      # Setup logging FIRST if block given (so swarm_start event can be emitted)
      setup_logging(logs, &block) if has_logging

      # Setup observer execution if any observers configured
      # MUST happen AFTER setup_logging (which clears Fiber[:log_subscriptions])
      setup_observer_execution if @observer_configs.any?

      # Trigger swarm_start hooks (before any execution)
      current_prompt = apply_swarm_start_hooks(current_prompt)

      # Trigger first_message hooks on first execution
      unless @first_message_sent
        trigger_first_message(current_prompt)
        @first_message_sent = true
      end

      # Lazy initialization of agents (with optional logging)
      initialize_agents unless @agents_initialized

      # Emit agent_start events if agents were initialized before logging was set up
      emit_retroactive_agent_start_events if has_logging

      # Delegate to Executor for actual execution
      executor = Executor.new(self)
      @current_task = executor.run(
        current_prompt,
        wait: wait,
        logs: logs,
        has_logging: has_logging,
        original_fiber_storage: original_fiber_storage,
      )
    end

    # Get an agent chat instance by name
    #
    # @param name [Symbol, String] Agent name
    # @return [AgentChat] Agent chat instance
    def agent(name)
      name = name.to_sym
      initialize_agents unless @agents_initialized

      @agents[name] || raise(AgentNotFoundError, "Agent '#{name}' not found")
    end

    # Get an agent definition by name
    #
    # Use this to access and modify agent configuration:
    #   swarm.agent_definition(:backend).bypass_permissions = true
    #
    # @param name [Symbol, String] Agent name
    # @return [AgentDefinition] Agent definition object
    def agent_definition(name)
      name = name.to_sym

      @agent_definitions[name] || raise(AgentNotFoundError, "Agent '#{name}' not found")
    end

    # Get all agent names
    #
    # @return [Array<Symbol>] Agent names
    def agent_names
      @agent_definitions.keys
    end

    # Implement Snapshotable interface
    def primary_agents
      @agents
    end

    def delegation_instances_hash
      @delegation_instances
    end

    # NOTE: validate() and emit_validation_warnings() are provided by Concerns::Validatable
    # Note: cleanup() is provided by Concerns::Cleanupable

    # Register a named hook that can be referenced in agent configurations
    #
    # Named hooks are stored in the registry and can be referenced by symbol
    # in agent YAML configurations or programmatically.
    #
    # @param name [Symbol] Unique hook name
    # @param block [Proc] Hook implementation
    # @return [self]
    #
    # @example Register a validation hook
    #   swarm.register_hook(:validate_code) do |context|
    #     raise SwarmSDK::Hooks::Error, "Invalid" unless valid?(context.tool_call)
    #   end
    def register_hook(name, &block)
      @hook_registry.register(name, &block)
      self
    end

    # Reset context for all agents
    #
    # Clears conversation history for all agents. This is used by composable swarms
    # to reset sub-swarm context when keep_context: false is specified.
    #
    # @return [void]
    def reset_context!
      @agents.each_value do |agent_chat|
        agent_chat.clear_conversation if agent_chat.respond_to?(:clear_conversation)
      end
    end

    # Add observer configuration
    #
    # Called by Swarm::Builder to register observer agent configurations.
    # Validates that the referenced agent exists.
    #
    # @param config [Observer::Config] Observer configuration
    # @return [void]
    def add_observer_config(config)
      validate_observer_agent(config.agent_name)
      @observer_configs << config
    end

    # Wait for all observer tasks to complete
    #
    # Called by Executor to wait for observer agents before cleanup.
    # Safe to call even if no observers are configured.
    #
    # @return [void]
    def wait_for_observers
      @observer_manager&.wait_for_completion
    end

    # Cleanup observer subscriptions
    #
    # Called by Executor.cleanup_after_execution to unsubscribe observers.
    # Matches the MCP cleanup pattern.
    #
    # @return [void]
    def cleanup_observers
      @observer_manager&.cleanup
      @observer_manager = nil
    end

    # Create snapshot of current conversation state
    #
    # Returns a Snapshot object containing:
    # - All agent conversations (@messages arrays)
    # - Agent context state (warnings, compression, TodoWrite tracking, skills)
    # - Delegation instance conversations
    # - Scratchpad contents (volatile shared storage)
    # - Read tracking state (which files each agent has read with digests)
    # - Memory read tracking state (which memory entries each agent has read with digests)
    #
    # Configuration (agent definitions, tools, prompts) stays in your YAML/DSL
    # and is NOT included in snapshots.
    #
    # @return [Snapshot] Snapshot object with convenient serialization methods
    #
    # @example Save snapshot to JSON file
    #   snapshot = swarm.snapshot
    #   snapshot.write_to_file("session.json")
    #
    # @example Convert to hash or JSON string
    #   snapshot = swarm.snapshot
    #   hash = snapshot.to_hash
    #   json_string = snapshot.to_json
    def snapshot
      StateSnapshot.new(self).snapshot
    end

    # Restore conversation state from snapshot
    #
    # Accepts a Snapshot object, hash, or JSON string. Validates compatibility
    # between snapshot and current swarm configuration, restores agent conversations,
    # context state, scratchpad, and read tracking. Returns RestoreResult with
    # warnings about any agents that couldn't be restored due to configuration
    # mismatches.
    #
    # The swarm must be created with the SAME configuration (agent definitions,
    # tools, prompts) as when the snapshot was created. Only conversation state
    # is restored from the snapshot.
    #
    # @param snapshot [Snapshot, Hash, String] Snapshot object, hash, or JSON string
    # @return [RestoreResult] Result with warnings about skipped agents
    #
    # @example Restore from Snapshot object
    #   swarm = SwarmSDK.build { ... }  # Same config as snapshot
    #   snapshot = Snapshot.from_file("session.json")
    #   result = swarm.restore(snapshot)
    #   if result.success?
    #     puts "All agents restored"
    #   else
    #     puts result.summary
    #     result.warnings.each { |w| puts "  - #{w[:message]}" }
    #   end
    #
    # Restore swarm state from snapshot
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

    # Override swarm IDs for composable swarms
    #
    # Used by SwarmLoader to set hierarchical IDs when loading sub-swarms.
    # This is called after the swarm is built to ensure proper parent/child relationships.
    #
    # @param swarm_id [String] New swarm ID
    # @param parent_swarm_id [String] New parent swarm ID
    # @return [void]
    def override_swarm_ids(swarm_id:, parent_swarm_id:)
      @swarm_id = swarm_id
      @parent_swarm_id = parent_swarm_id
    end

    # Set swarm registry for composable swarms
    #
    # Used by Builder to set the registry after swarm creation.
    # This must be called before agent initialization to enable swarm delegation.
    #
    # @param registry [SwarmRegistry] Configured swarm registry
    # @return [void]
    attr_writer :swarm_registry

    # --- Internal API (for Executor use only) ---
    # Hook triggers for swarm lifecycle events are provided by HookTriggers module

    private

    # Apply swarm_start hooks to prompt
    #
    # @param prompt [String] Original prompt
    # @return [String] Modified prompt (possibly with hook context appended)
    def apply_swarm_start_hooks(prompt)
      swarm_start_result = trigger_swarm_start(prompt)
      if swarm_start_result&.replace?
        "#{prompt}\n\n<hook-context>\n#{swarm_start_result.value}\n</hook-context>"
      else
        prompt
      end
    end

    # Validate that observer agent exists
    #
    # @param agent_name [Symbol] Name of the observer agent
    # @raise [ConfigurationError] If agent not found
    # @return [void]
    def validate_observer_agent(agent_name)
      return if @agent_definitions.key?(agent_name)

      raise ConfigurationError,
        "Observer agent '#{agent_name}' not found. " \
          "Define the agent first with `agent :#{agent_name} do ... end`"
    end

    # Setup observer manager and subscriptions
    #
    # Creates Observer::Manager and registers event subscriptions.
    # Must be called AFTER setup_logging (which clears Fiber[:log_subscriptions]).
    #
    # @return [void]
    def setup_observer_execution
      @observer_manager = Observer::Manager.new(self)
      @observer_configs.each { |c| @observer_manager.add_config(c) }
      @observer_manager.setup
    end

    # Validate and normalize scratchpad mode for Swarm
    #
    # Regular Swarms support :enabled or :disabled.
    # Rejects :per_node since it only makes sense for Workflow with multiple nodes.
    #
    # @param value [Symbol, String] Scratchpad mode (strings from YAML converted to symbols)
    # @return [Symbol] :enabled or :disabled
    # @raise [ArgumentError] If :per_node used, or invalid value
    def validate_swarm_scratchpad_mode(value)
      # Convert strings from YAML to symbols
      value = value.to_sym if value.is_a?(String)

      case value
      when :enabled, :disabled
        value
      when :per_node
        raise ArgumentError,
          "scratchpad: :per_node is only valid for Workflow with nodes. " \
            "For regular Swarms, use :enabled or :disabled."
      else
        raise ArgumentError,
          "Invalid scratchpad mode for Swarm: #{value.inspect}. " \
            "Use :enabled or :disabled."
      end
    end

    # Generate a unique swarm ID from name
    #
    # Creates a swarm ID by sanitizing the name and appending a random suffix.
    # Used when swarm_id is not explicitly provided.
    #
    # @param name [String] Swarm name
    # @return [String] Generated swarm ID (e.g., "dev_team_a3f2b1c8")
    def generate_swarm_id(name)
      sanitized = name.to_s.gsub(/[^a-z0-9_-]/i, "_").downcase
      "#{sanitized}_#{SecureRandom.hex(4)}"
    end

    # Generate a unique execution ID
    #
    # Creates an execution ID that uniquely identifies a single swarm.execute() call.
    # Format: "exec_{swarm_id}_{random_hex}"
    #
    # @return [String] Generated execution ID (e.g., "exec_main_a3f2b1c8")
    def generate_execution_id
      "exec_#{@swarm_id}_#{SecureRandom.hex(8)}"
    end

    # Initialize all agents using AgentInitializer
    #
    # This is called automatically (lazy initialization) by execute() and agent().
    # Delegates to AgentInitializer which handles the complex 5-pass setup.
    #
    # @return [void]
    def initialize_agents
      return if @agents_initialized

      initializer = AgentInitializer.new(self)

      @agents = initializer.initialize_all
      @agent_contexts = initializer.agent_contexts
      @agents_initialized = true

      # NOTE: agent_start events are emitted in execute() when logging is set up
      # This ensures events are never lost, even if agents are initialized early (e.g., by restore())
    end

    # Normalize tools to internal format (kept for add_agent)
    #
    # Handles both Ruby API (simple symbols) and YAML API (already parsed configs)
    #
    # @param tools [Array] Tool specifications
    # @return [Array<Hash>] Normalized tool configs
    def normalize_tools(tools)
      Array(tools).map do |tool|
        case tool
        when Symbol, String
          # Simple tool from Ruby API
          { name: tool.to_sym, permissions: nil }
        when Hash
          # Already in config format from YAML (has :name and :permissions keys)
          if tool.key?(:name)
            tool
          else
            # Inline permissions format: { Write: { allowed_paths: [...] } }
            tool_name = tool.keys.first.to_sym
            { name: tool_name, permissions: tool[tool_name] }
          end
        else
          raise ConfigurationError, "Invalid tool specification: #{tool.inspect}"
        end
      end
    end

    # Delegation methods for testing (delegate to concerns)
    # These allow tests to verify behavior without depending on internal structure

    # Create a tool instance (delegates to ToolConfigurator)
    def create_tool_instance(tool_name, agent_name, directory)
      ToolConfigurator.new(self, @scratchpad_storage, @plugin_storages).create_tool_instance(tool_name, agent_name, directory)
    end

    # Wrap tool with permissions (delegates to ToolConfigurator)
    def wrap_tool_with_permissions(tool_instance, permissions_config, agent_definition)
      ToolConfigurator.new(self, @scratchpad_storage, @plugin_storages).wrap_tool_with_permissions(tool_instance, permissions_config, agent_definition)
    end

    # Build MCP transport config (delegates to McpConfigurator)
    def build_mcp_transport_config(transport_type, config)
      McpConfigurator.new(self).build_transport_config(transport_type, config)
    end

    # Create delegation tool (delegates to AgentInitializer)
    def create_delegation_tool(name:, description:, delegate_chat:, agent_name:)
      AgentInitializer.new(self)
        .create_delegation_tool(name: name, description: description, delegate_chat: delegate_chat, agent_name: agent_name)
    end

    # Extract loggable info from plugin config
    #
    # Attempts to extract useful information from plugin configuration
    # for logging purposes. Handles MemoryConfig, Hashes, and other objects.
    #
    # @param config [Object] Plugin configuration object
    # @return [Hash, nil] Extracted config info or nil
    def extract_plugin_config_info(config)
      return if config.nil?

      # Handle MemoryConfig object (has directory method)
      if config.respond_to?(:directory)
        return { directory: config.directory }
      end

      # Handle Hash
      if config.is_a?(Hash)
        return config.slice(:directory, "directory", :adapter, "adapter")
      end

      # Unknown config type
      nil
    end
  end
end
