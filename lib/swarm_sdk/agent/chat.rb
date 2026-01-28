# frozen_string_literal: true

module SwarmSDK
  module Agent
    # Chat wraps RubyLLM::Chat to provide SwarmSDK orchestration capabilities
    #
    # ## Architecture
    #
    # This class uses **composition** with RubyLLM::Chat:
    # - RubyLLM::Chat handles: LLM API, messages, tools, concurrent execution
    # - SwarmSDK::Agent::Chat adds: hooks, reminders, semaphores, event enrichment
    #
    # ## ChatHelpers Module Architecture
    #
    # Chat is decomposed into 8 focused helper modules to manage complexity:
    #
    # ### Core Functionality
    # - **EventEmitter**: Multi-subscriber event callbacks for tool/lifecycle events.
    #   Provides `subscribe`, `emit_event`, `clear_subscribers` for observable behavior.
    # - **LoggingHelpers**: Formatting tool call information for structured JSON logs.
    #   Converts tool calls/results to loggable hashes with sanitization.
    # - **LlmConfiguration**: Model selection, provider setup, and API configuration.
    #   Resolves provider from model, handles model aliases, builds connection config.
    # - **SystemReminders**: Dynamic system message injection based on agent state.
    #   Collects reminders from plugins, context trackers, and other sources.
    #
    # ### Cross-Cutting Concerns
    # - **Instrumentation**: LLM API request/response logging via Faraday middleware.
    #   Wraps HTTP calls to capture timing, tokens, and error information.
    # - **HookIntegration**: Pre/post tool execution callbacks and delegation hooks.
    #   Integrates with SwarmSDK Hooks::Registry for lifecycle events.
    # - **TokenTracking**: Usage statistics and cost calculation per conversation.
    #   Accumulates input/output tokens across all LLM calls.
    #
    # ### State Management
    # - **Serialization**: Snapshot/restore for session persistence.
    #   Saves/restores message history, tool states, and agent context.
    #
    # ## Module Dependencies
    #
    #   EventEmitter <-- HookIntegration (event emission for hooks)
    #   TokenTracking <-- Instrumentation (usage data collection)
    #   SystemReminders <-- uses ContextTracker instance (not a module)
    #   LoggingHelpers <-- EventEmitter (log event formatting)
    #
    # ## Design Rationale
    #
    # This decomposition follows Single Responsibility Principle. Each module
    # handles one concern. They access shared Chat internals (@llm_chat,
    # @messages, etc.) which makes them tightly coupled to Chat, but this keeps
    # the main Chat class focused on orchestration rather than implementation
    # details. The modules are intentionally NOT standalone - they augment
    # Chat with specific capabilities.
    #
    # ## Rate Limiting Strategy
    #
    # Two-level semaphore system prevents API quota exhaustion in hierarchical agent trees:
    # 1. **Global semaphore** - Serializes ask() calls across entire swarm
    # 2. **Local semaphore** - Limits concurrent tool calls per agent (via RubyLLM)
    #
    # ## Event Flow
    #
    # RubyLLM events → SwarmSDK subscribes → enriches with context → emits SwarmSDK events
    # This allows hooks to fire on SwarmSDK events with full agent context.
    #
    # @see ChatHelpers::EventEmitter Event subscription and emission
    # @see ChatHelpers::Instrumentation API logging via Faraday middleware
    # @see ChatHelpers::Serialization State persistence (snapshot/restore)
    # @see ChatHelpers::HookIntegration Pre/post tool execution callbacks
    class Chat
      # Include event emitter for multi-subscriber callbacks
      include ChatHelpers::EventEmitter

      # Include logging helpers for tool call formatting
      include ChatHelpers::LoggingHelpers

      # Include hook integration for pre/post tool hooks
      include ChatHelpers::HookIntegration

      # Include LLM configuration helpers
      include ChatHelpers::LlmConfiguration

      # Include system reminder collection
      include ChatHelpers::SystemReminders

      # Include token tracking methods
      include ChatHelpers::TokenTracking

      # Include message serialization
      include ChatHelpers::Serialization

      # Include LLM instrumentation
      include ChatHelpers::Instrumentation

      # SwarmSDK-specific accessors
      attr_reader :global_semaphore,
        :real_model_info,
        :context_tracker,
        :context_manager,
        :agent_context,
        :last_todowrite_message_index,
        :tool_registry,
        :skill_state,
        :provider # Extracted from RubyLLM::Chat for instrumentation (not publicly accessible)

      # Setters for snapshot/restore
      attr_writer :last_todowrite_message_index, :active_skill_path

      # Initialize AgentChat with RubyLLM::Chat wrapper
      #
      # @param definition [Hash] Agent definition containing all configuration
      # @param agent_name [Symbol, nil] Agent identifier (for plugin callbacks)
      # @param global_semaphore [Async::Semaphore, nil] Shared across all agents
      # @param options [Hash] Additional options
      def initialize(definition:, agent_name: nil, global_semaphore: nil, **options)
        # Initialize event emitter system
        initialize_event_emitter

        # Extract configuration from definition
        model_id = definition[:model]
        provider_name = definition[:provider]
        context_window = definition[:context_window]
        max_concurrent_tools = definition[:max_concurrent_tools]
        base_url = definition[:base_url]
        api_version = definition[:api_version]
        request_timeout = definition[:request_timeout] || SwarmSDK.config.agent_request_timeout
        assume_model_exists = definition[:assume_model_exists]
        system_prompt = definition[:system_prompt]
        parameters = definition[:parameters]
        custom_headers = definition[:headers]

        # Agent identifier (for plugin callbacks)
        @agent_name = agent_name

        # Turn timeout (external timeout for entire ask() call)
        @turn_timeout = definition[:turn_timeout]

        # Streaming configuration
        @streaming_enabled = definition[:streaming]
        @last_chunk_type = nil # Track chunk type transitions

        # Context manager for ephemeral messages
        @context_manager = ContextManager.new

        # Rate limiting
        @global_semaphore = global_semaphore
        @explicit_context_window = context_window

        # Serialize ask() calls to prevent message corruption
        @ask_semaphore = Async::Semaphore.new(1)

        # Track TodoWrite usage for periodic reminders
        @last_todowrite_message_index = nil

        # Agent context for logging (set via setup_context)
        @agent_context = nil

        # Context tracker (created after agent_context is set)
        @context_tracker = nil

        # Tool registry for lazy tool activation (Phase 3 - Plan 025)
        @tool_registry = Agent::ToolRegistry.new

        # Track loaded skill state (Phase 2 - Plan 025)
        @skill_state = nil

        # Tool activation dependencies (set by setup_tool_activation after initialization)
        @tool_configurator = nil
        @agent_definition = nil

        # Create internal RubyLLM::Chat instance
        @llm_chat = create_llm_chat(
          model_id: model_id,
          provider_name: provider_name,
          base_url: base_url,
          api_version: api_version,
          timeout: request_timeout,
          assume_model_exists: assume_model_exists,
          max_concurrent_tools: max_concurrent_tools,
        )

        # Extract provider from RubyLLM::Chat for instrumentation
        # Must be done after create_llm_chat since with_responses_api() may swap provider
        # NOTE: RubyLLM doesn't expose provider publicly, but we need it for Faraday middleware
        # rubocop:disable Security/NoReflectionMethods
        @provider = @llm_chat.instance_variable_get(:@provider)
        # rubocop:enable Security/NoReflectionMethods

        # Try to fetch real model info for accurate context tracking
        fetch_real_model_info(model_id)

        # Configure system prompt, parameters, headers, and thinking
        configure_system_prompt(system_prompt) if system_prompt
        configure_parameters(parameters)
        configure_headers(custom_headers)
        configure_thinking(definition[:thinking])

        # Setup around_tool_execution hook for SwarmSDK orchestration
        setup_tool_execution_hook

        # Setup around_llm_request hook for ephemeral message injection
        setup_llm_request_hook

        # Setup event bridging from RubyLLM to SwarmSDK
        setup_event_bridging
      end

      # --- SwarmSDK Abstraction API ---
      # These methods provide SwarmSDK-specific semantics without exposing RubyLLM internals

      # Check if streaming is enabled for this agent
      #
      # @return [Boolean] true if streaming is enabled
      def streaming_enabled?
        @streaming_enabled
      end

      # Model information
      def model_id
        @llm_chat.model.id
      end

      def model_provider
        @llm_chat.model.provider
      end

      def model_context_window
        @real_model_info&.context_window || @llm_chat.model.context_window
      end

      # Tool introspection
      def has_tool?(name)
        @llm_chat.tools.key?(name.to_s) || @llm_chat.tools.key?(name.to_sym)
      end

      def tool_names
        @llm_chat.tools.values.map(&:name).sort
      end

      def tool_count
        @llm_chat.tools.size
      end

      def remove_tool(name)
        @llm_chat.tools.delete(name.to_s) || @llm_chat.tools.delete(name.to_sym)
      end

      # Direct access to tools hash for advanced operations
      #
      # Use with caution - prefer has_tool?, tool_names, remove_tool for most cases.
      # This is provided for:
      # - Direct tool execution in tests
      # - Advanced tool manipulation
      #
      # Returns a hash wrapper that supports both string and symbol keys for test convenience.
      #
      # @return [Hash] Tool name to tool instance mapping (supports symbol and string keys)
      def tools
        # Return a fresh wrapper each time (since @llm_chat.tools may change)
        SymbolKeyHash.new(@llm_chat.tools)
      end

      # Hash wrapper that supports both string and symbol keys
      #
      # This allows tests to use tools[:ToolName] or tools["ToolName"]
      # while RubyLLM internally uses string keys.
      class SymbolKeyHash < SimpleDelegator
        def [](key)
          __getobj__[key.to_s] || __getobj__[key.to_sym]
        end

        def key?(key)
          __getobj__.key?(key.to_s) || __getobj__.key?(key.to_sym)
        end
      end

      # Message introspection
      def message_count
        @llm_chat.messages.size
      end

      def has_user_message?
        @llm_chat.messages.any? { |msg| msg.role == :user }
      end

      def last_assistant_message
        @llm_chat.messages.reverse.find { |msg| msg.role == :assistant }
      end

      # Read-only access to conversation messages
      #
      # Returns a copy of the message array for safe enumeration.
      # External code should use this instead of internal_messages.
      #
      # @return [Array<RubyLLM::Message>] Copy of message array
      def messages
        @llm_chat.messages.dup
      end

      # Atomically replace all conversation messages
      #
      # Used for context compaction and state restoration.
      # This is the safe way to manipulate messages from external code.
      #
      # @param new_messages [Array<RubyLLM::Message>] New message array
      # @return [self] for chaining
      def replace_messages(new_messages)
        @llm_chat.messages.clear
        new_messages.each { |msg| @llm_chat.messages << msg }
        self
      end

      # Get all assistant messages
      #
      # @return [Array<RubyLLM::Message>] All assistant messages
      def assistant_messages
        @llm_chat.messages.select { |msg| msg.role == :assistant }
      end

      # Find the last message matching a condition
      #
      # @yield [msg] Block to test each message
      # @return [RubyLLM::Message, nil] Last matching message or nil
      def find_last_message(&block)
        @llm_chat.messages.reverse.find(&block)
      end

      # Find the index of last message matching a condition
      #
      # @yield [msg] Block to test each message
      # @return [Integer, nil] Index of last matching message or nil
      def find_last_message_index(&block)
        @llm_chat.messages.rindex(&block)
      end

      # Get tool names that are NOT delegation tools
      #
      # @return [Array<String>] Non-delegation tool names
      def non_delegation_tool_names
        if @agent_context
          @llm_chat.tools.keys.reject { |name| @agent_context.delegation_tool?(name.to_s) }
        else
          @llm_chat.tools.keys
        end
      end

      # Add an ephemeral reminder to the most recent message
      #
      # The reminder will be sent to the LLM but not persisted in message history.
      # This encapsulates the internal message array access.
      #
      # @param reminder [String] Reminder content to add
      # @return [void]
      def add_ephemeral_reminder(reminder)
        @context_manager&.add_ephemeral_reminder(reminder, messages_array: @llm_chat.messages)
      end

      # --- Setup Methods ---

      # Setup agent context
      #
      # @param context [Agent::Context] Agent context for this chat
      def setup_context(context)
        @agent_context = context
        @context_tracker = ChatHelpers::ContextTracker.new(self, context)
      end

      # Setup logging callbacks
      #
      # @return [void]
      def setup_logging
        raise StateError, "Agent context not set. Call setup_context first." unless @agent_context

        @context_tracker.setup_logging
        inject_llm_instrumentation
      end

      # Setup tool activation dependencies (Plan 025)
      #
      # Must be called after tool registration to enable permission wrapping during activation.
      #
      # @param tool_configurator [ToolConfigurator] Tool configuration helper
      # @param agent_definition [Agent::Definition] Agent definition object
      # @return [void]
      def setup_tool_activation(tool_configurator:, agent_definition:)
        @tool_configurator = tool_configurator
        @agent_definition = agent_definition
      end

      # Emit model lookup warning if one occurred during initialization
      #
      # @param agent_name [Symbol, String] The agent name for logging context
      def emit_model_lookup_warning(agent_name)
        return unless @model_lookup_error

        LogStream.emit(
          type: "model_lookup_warning",
          agent: agent_name,
          swarm_id: @agent_context&.swarm_id,
          parent_swarm_id: @agent_context&.parent_swarm_id,
          model: @model_lookup_error[:model],
          error_message: @model_lookup_error[:error_message],
          suggestions: @model_lookup_error[:suggestions].map { |s| { id: s.id, name: s.name, context_window: s.context_window } },
        )
      end

      # --- Adapter API (SwarmSDK-stable interface) ---

      # Configure system prompt for the conversation
      #
      # @param prompt [String] System prompt
      # @param replace [Boolean] Replace existing system messages if true
      # @return [self] for chaining
      def configure_system_prompt(prompt, replace: false)
        @llm_chat.with_instructions(prompt, replace: replace)
        self
      end

      # Add a tool to this chat
      #
      # @param tool [Class, RubyLLM::Tool] Tool class or instance
      # @return [self] for chaining
      def add_tool(tool)
        @llm_chat.with_tool(tool)
        self
      end

      # Complete the current conversation (no additional prompt)
      #
      # Delegates to RubyLLM::Chat#complete() which handles:
      # - LLM API calls (with around_llm_request hook for ephemeral injection)
      # - Tool execution (with around_tool_execution hook for SwarmSDK hooks)
      # - Automatic tool loop (continues until no more tool calls)
      #
      # SwarmSDK adds:
      # - Semaphore rate limiting (ask + global)
      # - Finish marker handling (finish_agent, finish_swarm)
      #
      # @param options [Hash] Additional options (currently unused, for future compatibility)
      # @param block [Proc] Optional streaming block
      # @return [RubyLLM::Message] LLM response
      def complete(**_options, &block)
        @ask_semaphore.acquire do
          execute_with_global_semaphore do
            result = catch(:finish_agent) do
              catch(:finish_swarm) do
                # Delegate to RubyLLM::Chat#complete()
                # Hooks handle ephemeral injection and tool orchestration
                @llm_chat.complete(&block)
              end
            end

            # Handle finish markers thrown by hooks
            handle_finish_marker(result)
          end
        end
      end

      # Load skill state (called by LoadSkill tool)
      #
      # @param state [Object, nil] Skill state object (from SwarmMemory), or nil to clear
      # @return [void]
      def load_skill_state(state)
        @skill_state = state
      end

      # Clear loaded skill (return to all tools)
      #
      # @return [void]
      def clear_skill
        @skill_state = nil
      end

      # Check if a skill is currently loaded
      #
      # @return [Boolean] True if a skill has been loaded
      def skill_loaded?
        !@skill_state.nil?
      end

      # Get active skill path (for backward compatibility)
      #
      # @return [String, nil] Path to loaded skill
      def active_skill_path
        @skill_state&.file_path
      end

      # Clear conversation history
      #
      # @return [void]
      def clear_conversation
        @llm_chat.reset_messages!
        @context_manager&.clear_ephemeral
      end

      # Activate tools for the current prompt (Plan 025: Lazy Tool Activation)
      #
      # Called before each LLM request to set active toolset based on skill state.
      # Replaces @llm_chat.tools with active subset from registry.
      #
      # This is public so it can be called during initialization to populate tools.
      #
      # Logic:
      # - If no skill loaded: ALL tools from registry
      # - If skill restricts tools: skill's tools + non-removable tools
      # - Skill permissions applied during activation (wrapping base_instance)
      #
      # @return [void]
      def activate_tools_for_prompt
        # Get active tools based on skill state
        active = @tool_registry.active_tools(
          skill_state: @skill_state,
          tool_configurator: @tool_configurator,
          agent_definition: @agent_definition,
        )

        # Replace RubyLLM::Chat tools with active subset
        # CRITICAL: RubyLLM looks up tools by SYMBOL keys, must store with symbols!
        @llm_chat.tools.clear
        active.each { |name, instance| @llm_chat.tools[name.to_sym] = instance }
      end

      # --- Core Conversation Methods ---

      # Send a message to the LLM and get a response
      #
      # This method:
      # 1. Serializes concurrent asks via @ask_semaphore
      # 2. Optionally clears conversation context (inside semaphore for safety)
      # 3. Adds CLEAN user message to history (no reminders)
      # 4. Injects system reminders as ephemeral content (sent to LLM but not stored)
      # 5. Triggers user_prompt hooks
      # 6. Acquires global semaphore for LLM call
      # 7. Delegates to RubyLLM::Chat for actual execution
      #
      # @param prompt [String] User prompt
      # @param clear_context [Boolean] When true, clears conversation history before
      #   processing. Clearing happens inside the ask_semaphore, making it safe for
      #   concurrent callers (e.g., parallel delegations to the same agent).
      # @param options [Hash] Additional options (source: for hooks)
      # @return [RubyLLM::Message] LLM response
      def ask(prompt, clear_context: false, **options)
        @ask_semaphore.acquire do
          # Clear inside semaphore so concurrent callers don't corrupt each other's messages
          clear_conversation if clear_context

          if @turn_timeout
            execute_with_turn_timeout(prompt, options)
          else
            execute_ask(prompt, options)
          end
        end
      end

      # Add a message to the conversation history
      #
      # Automatically extracts and strips system reminders, tracking them as ephemeral.
      #
      # @param message_or_attributes [RubyLLM::Message, Hash] Message object or attributes hash
      # @return [RubyLLM::Message] The added message
      def add_message(message_or_attributes)
        message = if message_or_attributes.is_a?(RubyLLM::Message)
          message_or_attributes
        else
          RubyLLM::Message.new(message_or_attributes)
        end

        # Extract system reminders if present
        content_str = message.content.is_a?(RubyLLM::Content) ? message.content.text : message.content.to_s

        if @context_manager.has_system_reminders?(content_str)
          reminders = @context_manager.extract_system_reminders(content_str)
          clean_content_str = @context_manager.strip_system_reminders(content_str)

          clean_content = if message.content.is_a?(RubyLLM::Content)
            RubyLLM::Content.new(clean_content_str, message.content.attachments)
          else
            clean_content_str
          end

          clean_message = RubyLLM::Message.new(
            role: message.role,
            content: clean_content,
            tool_call_id: message.tool_call_id,
            tool_calls: message.tool_calls,
            model_id: message.model_id,
            input_tokens: message.input_tokens,
            output_tokens: message.output_tokens,
            cached_tokens: message.cached_tokens,
            cache_creation_tokens: message.cache_creation_tokens,
          )

          @llm_chat.add_message(clean_message)

          # Track reminders as ephemeral
          reminders.each do |reminder|
            @context_manager.add_ephemeral_reminder(reminder, messages_array: messages)
          end

          clean_message
        else
          @llm_chat.add_message(message)
        end
      end

      private

      # Execute ask with turn timeout wrapper
      def execute_with_turn_timeout(prompt, options)
        task = Async::Task.current

        # Use barrier to track child tasks spawned during this turn
        # (includes RubyLLM's async tool execution when max_concurrent_tools is set)
        barrier = Async::Barrier.new

        begin
          task.with_timeout(
            @turn_timeout,
            TurnTimeoutError,
            "Agent turn timed out after #{@turn_timeout}s",
          ) do
            # Execute inside barrier to track child tasks
            barrier.async do
              execute_ask(prompt, options)
            end.wait
          end
        rescue TurnTimeoutError
          # Stop all child tasks
          barrier.stop

          emit_turn_timeout_event

          # Return error message as response so caller can handle gracefully
          # Format like other tool/delegation errors for natural flow
          # This message goes to the swarm/caller, NOT added to agent's conversation history
          RubyLLM::Message.new(
            role: :assistant,
            content: "Error: Request timed out after #{@turn_timeout}s. The agent did not complete its response within the time limit. Please try a simpler request or increase the turn timeout.",
            model_id: model_id,
          )
        ensure
          # Cleanup barrier if not already stopped
          barrier.stop unless barrier.empty?
        end
      end

      # Emit turn timeout event
      def emit_turn_timeout_event
        LogStream.emit(
          type: "turn_timeout",
          agent: @agent_name,
          swarm_id: @agent_context&.swarm_id,
          parent_swarm_id: @agent_context&.parent_swarm_id,
          limit: @turn_timeout,
          message: "Agent turn timed out after #{@turn_timeout}s",
        )
      end

      # Execute ask without timeout (original ask implementation)
      def execute_ask(prompt, options)
        is_first = first_message?

        # Collect system reminders to inject as ephemeral content
        reminders = collect_system_reminders(prompt, is_first)

        # Trigger user_prompt hook (with clean prompt, not reminders)
        source = options.delete(:source) || "user"
        final_prompt = prompt
        if @hook_executor
          hook_result = trigger_user_prompt(prompt, source: source)

          if hook_result[:halted]
            return RubyLLM::Message.new(
              role: :assistant,
              content: hook_result[:halt_message],
              model_id: model_id,
            )
          end

          final_prompt = hook_result[:modified_prompt] if hook_result[:modified_prompt]
        end

        # Add CLEAN user message to history (no reminders embedded)
        @llm_chat.add_message(role: :user, content: final_prompt)

        # Track reminders as ephemeral content for this LLM call only
        # They'll be injected by around_llm_request hook but not stored
        reminders.each do |reminder|
          @context_manager.add_ephemeral_reminder(reminder, messages_array: @llm_chat.messages)
        end

        # Execute complete() which handles tool loop and ephemeral injection
        response = execute_with_global_semaphore do
          catch(:finish_agent) do
            catch(:finish_swarm) do
              if @streaming_enabled
                # Reset chunk type tracking for new streaming request
                @last_chunk_type = nil

                @llm_chat.complete(**options) do |chunk|
                  emit_content_chunk(chunk)
                end
              else
                @llm_chat.complete(**options)
              end
            end
          end
        end

        # Handle finish markers from hooks
        handle_finish_marker(response)
      end

      # --- Tool Execution Hook ---

      # Setup around_tool_execution hook for SwarmSDK orchestration
      #
      # This hook intercepts all tool executions to:
      # - Trigger pre_tool_use hooks (can block, replace, or finish)
      # - Trigger post_tool_use hooks (can transform results)
      # - Handle finish markers
      def setup_tool_execution_hook
        @llm_chat.around_tool_execution do |tool_call, _tool_instance, execute|
          # Skip hooks for delegation tools (they have their own events)
          if delegation_tool_call?(tool_call)
            execute.call
          else
            # PRE-HOOK
            pre_result = trigger_pre_tool_use(tool_call)

            case pre_result
            when Hash
              if pre_result[:finish_agent]
                throw(:finish_agent, { __finish_agent__: true, message: pre_result[:custom_result] })
              elsif pre_result[:finish_swarm]
                throw(:finish_swarm, { __finish_swarm__: true, message: pre_result[:custom_result] })
              elsif !pre_result[:proceed]
                # Blocked - return custom result without executing
                next pre_result[:custom_result] || "Tool execution blocked by hook"
              end
            end

            # EXECUTE tool (no retry - failures are returned to LLM)
            result = execute.call

            # POST-HOOK
            post_result = trigger_post_tool_use(result, tool_call: tool_call)

            # Check for finish markers from post-hook
            if post_result.is_a?(Hash)
              if post_result[:__finish_agent__]
                throw(:finish_agent, post_result)
              elsif post_result[:__finish_swarm__]
                throw(:finish_swarm, post_result)
              end
            end

            post_result
          end
        end
      end

      # --- Event Bridging ---

      # Setup event bridging from RubyLLM to SwarmSDK
      #
      # Subscribes to RubyLLM events and emits enriched SwarmSDK events.
      def setup_event_bridging
        # Bridge tool_call events
        @llm_chat.on_tool_call do |tool_call|
          emit(:tool_call, tool_call)
        end

        # Bridge tool_result events
        @llm_chat.on_tool_result do |_tool_call, result|
          emit(:tool_result, result)
        end

        # Bridge new_message events
        @llm_chat.on_new_message do
          emit(:new_message)
        end

        # Bridge end_message events (used for agent_step/agent_stop)
        @llm_chat.on_end_message do |message|
          emit(:end_message, message)
        end
      end

      # --- LLM Request Hook ---

      # Setup around_llm_request hook for ephemeral message injection
      #
      # This hook intercepts all LLM API calls to:
      # - Activate tools based on skill state (Plan 025: Lazy Tool Activation)
      # - Inject ephemeral content (system reminders) that shouldn't be persisted
      # - Clear ephemeral content after each LLM call
      # - Add retry logic for transient failures
      def setup_llm_request_hook
        @llm_chat.around_llm_request do |_messages, &send_request|
          # Activate tools for this LLM request (Plan 025)
          # This happens before each LLM request to ensure tools match current skill state
          activate_tools_for_prompt

          # Make the actual LLM API call with retry logic
          # NOTE: prepare_for_llm must be called INSIDE the retry block so that
          # ephemeral content is recalculated after orphan tool call pruning
          begin
            call_llm_with_retry do
              # Inject ephemeral content fresh for each attempt
              # Use @llm_chat.messages to get current state (may have been modified by pruning)
              prepared_messages = @context_manager.prepare_for_llm(@llm_chat.messages)
              send_request.call(prepared_messages)
            end
          ensure
            # Always clear ephemeral content, even if streaming fails
            @context_manager.clear_ephemeral
          end
        end
      end

      # --- Semaphore and Reminder Management ---

      # Execute block with global semaphore
      #
      # @yield Block to execute
      # @return [Object] Result from block
      def execute_with_global_semaphore(&block)
        if @global_semaphore
          @global_semaphore.acquire(&block)
        else
          yield
        end
      end

      # Check if this is the first user message
      #
      # @return [Boolean] true if no user messages exist yet
      def first_message?
        !has_user_message?
      end

      # Handle finish markers from hooks
      #
      # @param response [Object] Response from ask (may be a finish marker hash)
      # @return [RubyLLM::Message] Final message
      def handle_finish_marker(response)
        if response.is_a?(Hash)
          if response[:__finish_agent__]
            message = RubyLLM::Message.new(
              role: :assistant,
              content: response[:message],
              model_id: model_id,
            )
            @context_tracker.finish_reason_override = "finish_agent" if @context_tracker
            emit(:end_message, message)
            message
          elsif response[:__finish_swarm__]
            # Propagate finish_swarm marker up
            response
          else
            # Regular response
            response
          end
        else
          response
        end
      end

      # --- LLM Call Retry Logic ---

      # Call LLM provider with smart retry logic based on error type
      #
      # ## Error Categorization
      #
      # **Non-Retryable Client Errors (4xx)**: Return error message immediately
      # - 400 Bad Request (after orphan tool call recovery attempt)
      # - 401 Unauthorized (invalid API key)
      # - 402 Payment Required (billing issue)
      # - 403 Forbidden (permission denied)
      # - 422 Unprocessable Entity (invalid parameters)
      # - Other 4xx errors
      #
      # **Retryable Server Errors (5xx)**: Retry with delays
      # - 429 Rate Limit (RubyLLM already retried 3x)
      # - 500 Server Error (RubyLLM already retried 3x)
      # - 502-503 Service Unavailable (RubyLLM already retried 3x)
      # - 529 Overloaded (RubyLLM already retried 3x)
      # Note: If we see these errors, RubyLLM has already tried 3 times
      #
      # **Network Errors**: Retry with delays
      # - Timeouts, connection failures, etc.
      #
      # ## Special Handling
      #
      # **400 Bad Request with Orphan Tool Calls**:
      # - Attempts to prune orphan tool calls (tool_use without tool_result)
      # - If pruning succeeds, retries immediately without counting as retry
      # - If pruning fails or not applicable, returns error message immediately
      #
      # ## Error Response Format
      #
      # Non-retryable errors return as assistant messages for natural delegation flow:
      # ```ruby
      # RubyLLM::Message.new(
      #   role: :assistant,
      #   content: "I encountered an error: [details]"
      # )
      # ```
      #
      # @param max_retries [Integer] Maximum retry attempts at SDK level
      #   Note: RubyLLM already retries 429/5xx errors 3 times before this
      # @param delay [Integer] Delay between retries in seconds
      # @yield Block that performs the LLM call
      # @return [RubyLLM::Message, Object] Result from block or error message
      #
      # @example Handling 401 Unauthorized
      #   result = call_llm_with_retry do
      #     @llm_chat.complete
      #   end
      #   # Returns immediately: Message with "Unauthorized" error
      #
      # @example Handling 500 Server Error
      #   result = call_llm_with_retry(max_retries: 3, delay: 15) do
      #     @llm_chat.complete
      #   end
      #   # Retries up to 3 times with 15s delays
      #   # (RubyLLM already tried 3x, so 6 total attempts)
      def call_llm_with_retry(max_retries: 3, delay: 15, &block)
        attempts = 0
        pruning_attempted = false

        loop do
          attempts += 1

          begin
            return yield

          # === CATEGORY A: NON-RETRYABLE CLIENT ERRORS ===
          rescue RubyLLM::BadRequestError => e
            # Special case: Try orphan tool call recovery ONCE
            # This handles interrupted tool executions (tool_use without tool_result)
            unless pruning_attempted
              pruned = recover_from_orphan_tool_calls(e)
              if pruned > 0
                pruning_attempted = true
                attempts -= 1 # Don't count as retry
                next
              end
            end

            # No recovery possible - fail immediately with error message
            emit_non_retryable_error(e, "BadRequest")
            return build_error_message(e)
          rescue RubyLLM::UnauthorizedError => e
            # 401: Authentication failed - won't fix by retrying
            emit_non_retryable_error(e, "Unauthorized")
            return build_error_message(e)
          rescue RubyLLM::PaymentRequiredError => e
            # 402: Billing issue - won't fix by retrying
            emit_non_retryable_error(e, "PaymentRequired")
            return build_error_message(e)
          rescue RubyLLM::ForbiddenError => e
            # 403: Permission denied - won't fix by retrying
            emit_non_retryable_error(e, "Forbidden")
            return build_error_message(e)

          # === CATEGORY B: RETRYABLE SERVER ERRORS ===
          # IMPORTANT: Must come BEFORE generic RubyLLM::Error to avoid being caught by it
          rescue RubyLLM::RateLimitError,
                 RubyLLM::ServerError,
                 RubyLLM::ServiceUnavailableError,
                 RubyLLM::OverloadedError => e
            # These errors indicate temporary provider issues
            # RubyLLM already retried 3 times with exponential backoff (~0.7s)
            # Retry a few more times with longer delays to give provider time
            handle_retry_or_raise(e, attempts, max_retries, delay)

          # === CATEGORY A (CONTINUED): OTHER CLIENT ERRORS ===
          # IMPORTANT: Must come AFTER specific error classes (including server errors)
          rescue RubyLLM::Error => e
            # Generic RubyLLM::Error - check for specific status codes
            if e.response&.status == 422
              # 422: Unprocessable Entity - semantic validation failure
              emit_non_retryable_error(e, "UnprocessableEntity")
              return build_error_message(e)
            elsif e.response&.status && (400..499).include?(e.response.status)
              # Other 4xx errors - conservative: don't retry unknown client errors
              emit_non_retryable_error(e, "ClientError")
              return build_error_message(e)
            end

            # Unknown error type without status code - conservative: don't retry
            emit_non_retryable_error(e, "UnknownAPIError")
            return build_error_message(e)

          # === CATEGORY A (CONTINUED): PROGRAMMING ERRORS ===
          rescue ArgumentError, TypeError, NameError => e
            # Programming errors (wrong keywords, type mismatches) - won't fix by retrying
            emit_non_retryable_error(e, e.class.name)
            return build_error_message(e)

          # === CATEGORY C: NETWORK/OTHER ERRORS ===
          rescue StandardError => e
            # Network errors, timeouts, unknown errors - retry with delays
            handle_retry_or_raise(e, attempts, max_retries, delay)
          end
        end
      end

      # Handle retry decision or re-raise error
      #
      # @param error [StandardError] The error that occurred
      # @param attempts [Integer] Current attempt count
      # @param max_retries [Integer] Maximum retry attempts
      # @param delay [Integer] Delay between retries in seconds
      # @raise [StandardError] Re-raises error if max retries exceeded
      def handle_retry_or_raise(error, attempts, max_retries, delay)
        if attempts >= max_retries
          LogStream.emit(
            type: "llm_retry_exhausted",
            agent: @agent_name,
            swarm_id: @agent_context&.swarm_id,
            parent_swarm_id: @agent_context&.parent_swarm_id,
            model: model_id,
            attempts: attempts,
            error_class: error.class.name,
            error_message: error.message,
            error_backtrace: error.backtrace,
          )
          raise
        end

        LogStream.emit(
          type: "llm_retry_attempt",
          agent: @agent_name,
          swarm_id: @agent_context&.swarm_id,
          parent_swarm_id: @agent_context&.parent_swarm_id,
          model: model_id,
          attempt: attempts,
          max_retries: max_retries,
          error_class: error.class.name,
          error_message: error.message,
          error_backtrace: error.backtrace,
          retry_delay: delay,
        )

        sleep(delay)
      end

      # Build an error message as an assistant response
      #
      # Non-retryable errors are returned as assistant messages instead of raising.
      # This allows errors to flow naturally through delegation - parent agents
      # can see child agent errors and respond appropriately.
      #
      # @param error [RubyLLM::Error, StandardError] The error that occurred
      # @return [RubyLLM::Message] Assistant message containing formatted error
      #
      # @example Error message for delegation
      #   error = RubyLLM::UnauthorizedError.new(response, "Invalid API key")
      #   message = build_error_message(error)
      #   # => Message with role: :assistant, content: "I encountered an error: ..."
      def build_error_message(error)
        content = format_error_message(error)

        RubyLLM::Message.new(
          role: :assistant,
          content: content,
          model_id: model_id,
        )
      end

      # Format error details into user-friendly message
      #
      # @param error [RubyLLM::Error, StandardError] The error to format
      # @return [String] Formatted error message with type, status, and guidance
      #
      # @example Formatting 401 error
      #   format_error_message(unauthorized_error)
      #   # => "I encountered an error while processing your request:
      #   #     **Error Type:** UnauthorizedError
      #   #     **Status Code:** 401
      #   #     **Message:** Invalid API key
      #   #     Please check your API credentials."
      def format_error_message(error)
        status = error.respond_to?(:response) ? error.response&.status : nil

        msg = "I encountered an error while processing your request:\n\n"
        msg += "**Error Type:** #{error.class.name.split("::").last}\n"
        msg += "**Status Code:** #{status}\n" if status
        msg += "**Message:** #{error.message}\n\n"
        msg += "This error indicates a problem that cannot be automatically recovered. "

        # Add context-specific guidance based on error type
        msg += case error
        when RubyLLM::UnauthorizedError
          "Please check your API credentials."
        when RubyLLM::PaymentRequiredError
          "Please check your account billing status."
        when RubyLLM::ForbiddenError
          "You may not have permission to access this resource."
        when RubyLLM::BadRequestError
          "The request format may be invalid."
        else
          "Please review the error and try again."
        end

        msg
      end

      # Emit llm_request_failed event for non-retryable errors
      #
      # This event provides visibility into errors that fail immediately
      # without retry attempts. Useful for monitoring auth failures,
      # billing issues, and other non-transient problems.
      #
      # @param error [RubyLLM::Error, StandardError] The error that occurred
      # @param error_type [String] Friendly error type name for logging
      # @return [void]
      #
      # @example Emitting unauthorized error event
      #   emit_non_retryable_error(error, "Unauthorized")
      #   # Emits: { type: "llm_request_failed", error_type: "Unauthorized", ... }
      def emit_non_retryable_error(error, error_type)
        LogStream.emit(
          type: "llm_request_failed",
          agent: @agent_name,
          swarm_id: @agent_context&.swarm_id,
          parent_swarm_id: @agent_context&.parent_swarm_id,
          model: model_id,
          error_type: error_type,
          error_class: error.class.name,
          error_message: error.message,
          status_code: error.respond_to?(:response) ? error.response&.status : nil,
          retryable: false,
        )
      end

      # Emit content_chunk event during streaming
      #
      # This method is called for each chunk received during streaming.
      # It emits a content_chunk event with the chunk's content and metadata.
      #
      # Additionally detects transitions from content → tool_call chunks and emits
      # a separator event to help UI layers distinguish "thinking" from tool execution.
      #
      # IMPORTANT: chunk.tool_calls contains PARTIAL data during streaming:
      # - tool_call.id and tool_call.name are available once the tool call starts
      # - tool_call.arguments are RAW STRING FRAGMENTS, not parsed JSON
      # Users should use `tool_call` events (after streaming) for complete data.
      #
      # @param chunk [RubyLLM::Chunk] A streaming chunk from the LLM
      # @return [void]
      def emit_content_chunk(chunk)
        # Determine chunk type using RubyLLM's tool_call? method
        # Content and tool_calls are mutually exclusive in chunks
        is_tool_call_chunk = chunk.tool_call?
        has_content = !chunk.content.nil?

        # Only emit if there's content or tool calls
        return unless is_tool_call_chunk || has_content

        # Detect transition from content chunks to tool_call chunks
        # This happens when the LLM finishes "thinking" text and starts calling tools
        current_chunk_type = is_tool_call_chunk ? "tool_call" : "content"
        if @last_chunk_type == "content" && current_chunk_type == "tool_call"
          # Emit separator event to signal end of thinking text
          LogStream.emit(
            type: "content_chunk",
            agent: @agent_name,
            chunk_type: "separator",
            content: nil,
            tool_calls: nil,
            model: chunk.model_id,
          )
        end
        @last_chunk_type = current_chunk_type

        # Transform tool_calls to serializable format
        # NOTE: arguments are partial strings during streaming!
        tool_calls_data = if is_tool_call_chunk
          chunk.tool_calls.transform_values do |tc|
            {
              id: tc.id,
              name: tc.name,
              arguments: tc.arguments, # PARTIAL string fragments!
            }
          end
        end

        LogStream.emit(
          type: "content_chunk",
          agent: @agent_name,
          chunk_type: current_chunk_type,
          content: chunk.content,
          tool_calls: tool_calls_data,
          model: chunk.model_id,
        )
      rescue StandardError => e
        # Never interrupt streaming due to event emission failure
        # LogCollector already isolates subscriber errors, but we're defensive here
        RubyLLM.logger.error("SwarmSDK: Failed to emit content_chunk: #{e.message}")
      end

      # Recover from 400 Bad Request by pruning orphan tool calls
      #
      # @param error [RubyLLM::BadRequestError] The error that occurred
      # @return [Integer] Number of orphan tool calls pruned (0 if none or not applicable)
      def recover_from_orphan_tool_calls(error)
        # Only attempt recovery for tool-related errors
        error_message = error.message.to_s.downcase
        tool_error_patterns = [
          "tool_use",
          "tool_result",
          "tool_use_id",
          "tool use",
          "tool result",
          "corresponding tool_result",
          "must immediately follow",
        ]

        return 0 unless tool_error_patterns.any? { |pattern| error_message.include?(pattern) }

        # Clear stale ephemeral content from the failed LLM call
        # This is important because message indices changed after pruning
        @context_manager&.clear_ephemeral

        # Attempt to prune orphan tool calls
        result = prune_orphan_tool_calls
        pruned_count = result[:count]

        if pruned_count > 0
          LogStream.emit(
            type: "orphan_tool_calls_pruned",
            agent: @agent_name,
            swarm_id: @agent_context&.swarm_id,
            parent_swarm_id: @agent_context&.parent_swarm_id,
            model: model_id,
            pruned_count: pruned_count,
            original_error: error.message,
          )

          # Add system reminder about pruned tool calls
          add_orphan_tool_calls_reminder(result[:pruned_tools])
        end

        pruned_count
      end

      # Prune orphan tool calls from message history
      #
      # An orphan tool call is a tool_use in an assistant message that doesn't
      # have a corresponding tool_result before the next user/assistant message.
      #
      # @return [Hash] { count: Integer, pruned_tools: Array<Hash> }
      def prune_orphan_tool_calls
        messages = @llm_chat.messages
        return { count: 0, pruned_tools: [] } if messages.empty?

        orphans = find_orphan_tool_calls(messages)
        return { count: 0, pruned_tools: [] } if orphans.empty?

        # Collect details about pruned tool calls
        pruned_tools = collect_orphan_tool_details(messages, orphans)

        # Build new message array with orphans removed
        new_messages = remove_orphan_tool_calls(messages, orphans)

        # Replace messages atomically
        replace_messages(new_messages)

        {
          count: orphans.values.flatten.size,
          pruned_tools: pruned_tools,
        }
      end

      # Collect details about orphan tool calls for system reminder
      #
      # @param messages [Array<RubyLLM::Message>] Original messages
      # @param orphans [Hash<Integer, Array<String>>] Map of message index to orphan tool_call_ids
      # @return [Array<Hash>] Array of { name:, arguments: } hashes
      def collect_orphan_tool_details(messages, orphans)
        pruned_tools = []

        orphans.each do |msg_idx, orphan_ids|
          msg = messages[msg_idx]
          next unless msg.tool_calls

          orphan_ids.each do |tool_call_id|
            tool_call = msg.tool_calls[tool_call_id]
            next unless tool_call

            pruned_tools << {
              name: tool_call.name,
              arguments: tool_call.arguments,
            }
          end
        end

        pruned_tools
      end

      # Add system reminder about pruned orphan tool calls
      #
      # @param pruned_tools [Array<Hash>] Array of { name:, arguments: } hashes
      # @return [void]
      def add_orphan_tool_calls_reminder(pruned_tools)
        return if pruned_tools.empty?

        # Format tool calls for the reminder
        tool_list = pruned_tools.map do |tool|
          args_str = format_tool_arguments(tool[:arguments])
          "- #{tool[:name]}(#{args_str})"
        end.join("\n")

        reminder = <<~REMINDER
          <system-reminder>
          The following tool calls were interrupted and removed from conversation history:

          #{tool_list}

          These tools were never executed. If you still need their results, please run them again.
          </system-reminder>
        REMINDER

        add_ephemeral_reminder(reminder.strip)
      end

      # Format tool arguments for display in reminder
      #
      # @param arguments [Hash] Tool call arguments
      # @return [String] Formatted arguments
      def format_tool_arguments(arguments)
        return "" if arguments.nil? || arguments.empty?

        # Format key-value pairs, truncating long values
        args = arguments.map do |key, value|
          formatted_value = if value.is_a?(String) && value.length > 50
            "#{value[0...47]}..."
          else
            value.inspect
          end
          "#{key}: #{formatted_value}"
        end

        args.join(", ")
      end

      # Find all orphan tool calls in message history
      #
      # @param messages [Array<RubyLLM::Message>] Message array to scan
      # @return [Hash<Integer, Array<String>>] Map of message index to orphan tool_call_ids
      def find_orphan_tool_calls(messages)
        orphans = {}

        messages.each_with_index do |msg, idx|
          next unless msg.role == :assistant && msg.tool_calls && !msg.tool_calls.empty?

          # Get all tool_call_ids from this assistant message
          expected_tool_call_ids = msg.tool_calls.keys.to_set

          # Find tool results between this message and the next user/assistant message
          found_tool_call_ids = Set.new

          (idx + 1...messages.size).each do |subsequent_idx|
            subsequent_msg = messages[subsequent_idx]

            # Stop at next user or assistant message
            break if [:user, :assistant].include?(subsequent_msg.role)

            # Collect tool result IDs
            if subsequent_msg.role == :tool && subsequent_msg.tool_call_id
              found_tool_call_ids << subsequent_msg.tool_call_id
            end
          end

          # Identify orphan tool_call_ids (expected but not found)
          orphan_ids = (expected_tool_call_ids - found_tool_call_ids).to_a
          orphans[idx] = orphan_ids unless orphan_ids.empty?
        end

        orphans
      end

      # Remove orphan tool calls from messages
      #
      # @param messages [Array<RubyLLM::Message>] Original messages
      # @param orphans [Hash<Integer, Array<String>>] Map of message index to orphan tool_call_ids
      # @return [Array<RubyLLM::Message>] New message array with orphans removed
      def remove_orphan_tool_calls(messages, orphans)
        messages.map.with_index do |msg, idx|
          orphan_ids = orphans[idx]

          # No orphans in this message - keep as-is
          next msg unless orphan_ids

          # Remove orphan tool_calls from this assistant message
          remaining_tool_calls = msg.tool_calls.reject { |id, _| orphan_ids.include?(id) }

          # If no tool_calls remain and no content, skip this message entirely
          if remaining_tool_calls.empty? && (msg.content.nil? || msg.content.to_s.strip.empty?)
            next nil
          end

          # Create new message with remaining tool_calls
          RubyLLM::Message.new(
            role: msg.role,
            content: msg.content,
            tool_calls: remaining_tool_calls.empty? ? nil : remaining_tool_calls,
            model_id: msg.model_id,
            input_tokens: msg.input_tokens,
            output_tokens: msg.output_tokens,
            cached_tokens: msg.cached_tokens,
            cache_creation_tokens: msg.cache_creation_tokens,
          )
        end.compact
      end

      # Check if a tool call is a delegation tool
      #
      # @param tool_call [RubyLLM::ToolCall] Tool call to check
      # @return [Boolean] true if this is a delegation tool
      def delegation_tool_call?(tool_call)
        return false unless @agent_context

        @agent_context.delegation_tool?(tool_call.name)
      end
    end
  end
end
