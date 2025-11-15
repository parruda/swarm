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

      # Register custom provider for responses API support
      unless RubyLLM::Provider.providers.key?(:openai_with_responses)
        RubyLLM::Provider.register(:openai_with_responses, SwarmSDK::Providers::OpenAIWithResponses)
      end

      # SwarmSDK-specific accessors
      attr_reader :global_semaphore,
        :real_model_info,
        :context_tracker,
        :context_manager,
        :agent_context,
        :last_todowrite_message_index,
        :active_skill_path,
        :provider # Stored during initialization since RubyLLM::Chat doesn't expose it

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
        timeout = definition[:timeout] || Definition::DEFAULT_TIMEOUT
        assume_model_exists = definition[:assume_model_exists]
        system_prompt = definition[:system_prompt]
        parameters = definition[:parameters]
        custom_headers = definition[:headers]

        # Agent identifier (for plugin callbacks)
        @agent_name = agent_name

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

        # Track immutable tools
        @immutable_tool_names = Set.new(["Think", "Clock", "TodoWrite"])

        # Track active skill (only used if memory enabled)
        @active_skill_path = nil

        # Create internal RubyLLM::Chat instance and extract provider
        @llm_chat, @provider = create_llm_chat(
          model_id: model_id,
          provider_name: provider_name,
          base_url: base_url,
          api_version: api_version,
          timeout: timeout,
          assume_model_exists: assume_model_exists,
          max_concurrent_tools: max_concurrent_tools,
        )

        # Try to fetch real model info for accurate context tracking
        fetch_real_model_info(model_id)

        # Configure system prompt, parameters, and headers
        configure_system_prompt(system_prompt) if system_prompt
        configure_parameters(parameters)
        configure_headers(custom_headers)

        # Setup around_tool_execution hook for SwarmSDK orchestration
        setup_tool_execution_hook

        # Setup around_llm_request hook for ephemeral message injection
        setup_llm_request_hook

        # Setup event bridging from RubyLLM to SwarmSDK
        setup_event_bridging
      end

      # --- SwarmSDK Abstraction API ---
      # These methods provide SwarmSDK-specific semantics without exposing RubyLLM internals

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

      # --- Internal Access (for helper modules only) ---
      # These methods provide raw access to RubyLLM internals for internal Chat modules
      # (ContextTracker, SystemReminderInjector, HookIntegration, etc.)
      # DO NOT use these in external SDK code - use the abstraction methods above

      # @!visibility private
      def internal_messages
        @llm_chat.messages
      end

      # @!visibility private
      def internal_tools
        @llm_chat.tools
      end

      # @!visibility private
      def internal_model
        @llm_chat.model
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

      # Mark tools as immutable (cannot be removed by dynamic tool swapping)
      #
      # @param tool_names [Array<String>] Tool names to mark as immutable
      def mark_tools_immutable(*tool_names)
        @immutable_tool_names.merge(tool_names.flatten.map(&:to_s))
      end

      # Remove all mutable tools (keeps immutable tools)
      #
      # @return [void]
      def remove_mutable_tools
        mutable_tool_names = tools.keys.reject { |name| @immutable_tool_names.include?(name.to_s) }
        mutable_tool_names.each { |name| tools.delete(name) }
      end

      # Mark skill as loaded (tracking for debugging/logging)
      #
      # @param file_path [String] Path to loaded skill
      def mark_skill_loaded(file_path)
        @active_skill_path = file_path
      end

      # Check if a skill is currently loaded
      #
      # @return [Boolean] True if a skill has been loaded
      def skill_loaded?
        !@active_skill_path.nil?
      end

      # Clear conversation history
      #
      # @return [void]
      def clear_conversation
        @llm_chat.reset_messages!
        @context_manager&.clear_ephemeral
      end

      # --- Core Conversation Methods ---

      # Send a message to the LLM and get a response
      #
      # This method:
      # 1. Serializes concurrent asks via @ask_semaphore
      # 2. Adds CLEAN user message to history (no reminders)
      # 3. Injects system reminders as ephemeral content (sent to LLM but not stored)
      # 4. Triggers user_prompt hooks
      # 5. Acquires global semaphore for LLM call
      # 6. Delegates to RubyLLM::Chat for actual execution
      #
      # @param prompt [String] User prompt
      # @param options [Hash] Additional options (source: for hooks)
      # @return [RubyLLM::Message] LLM response
      def ask(prompt, **options)
        @ask_semaphore.acquire do
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
                @llm_chat.complete(**options)
              end
            end
          end

          # Handle finish markers from hooks
          handle_finish_marker(response)
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
      # - Inject ephemeral content (system reminders) that shouldn't be persisted
      # - Clear ephemeral content after each LLM call
      # - Add retry logic for transient failures
      def setup_llm_request_hook
        @llm_chat.around_llm_request do |messages, &send_request|
          # Inject ephemeral content (system reminders, etc.)
          # These are sent to LLM but NOT persisted in message history
          prepared_messages = @context_manager.prepare_for_llm(messages)

          # Make the actual LLM API call with retry logic
          response = call_llm_with_retry do
            send_request.call(prepared_messages)
          end

          # Clear ephemeral content after successful call
          @context_manager.clear_ephemeral

          response
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

      # Call LLM provider with retry logic for transient failures
      #
      # @param max_retries [Integer] Maximum retry attempts
      # @param delay [Integer] Delay between retries in seconds
      # @yield Block that performs the LLM call
      # @return [Object] Result from block
      def call_llm_with_retry(max_retries: 10, delay: 10, &block)
        attempts = 0

        loop do
          attempts += 1

          begin
            return yield
          rescue StandardError => e
            if attempts >= max_retries
              LogStream.emit(
                type: "llm_retry_exhausted",
                agent: @agent_name,
                swarm_id: @agent_context&.swarm_id,
                parent_swarm_id: @agent_context&.parent_swarm_id,
                model: model_id,
                attempts: attempts,
                error_class: e.class.name,
                error_message: e.message,
                error_backtrace: e.backtrace,
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
              error_class: e.class.name,
              error_message: e.message,
              error_backtrace: e.backtrace,
              retry_delay: delay,
            )

            sleep(delay)
          end
        end
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
