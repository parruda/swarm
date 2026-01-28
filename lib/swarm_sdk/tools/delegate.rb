# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Delegate tool for working with other agents in the swarm
    #
    # Creates agent-specific collaboration tools (e.g., WorkWithBackend)
    # that allow one agent to work with another agent.
    # Supports pre/post delegation hooks for customization.
    class Delegate < Base
      removable true # Delegate tools can be controlled by skills
      # Tool name prefix for delegation tools
      # Change this to customize the tool naming pattern (e.g., "DelegateTaskTo", "AskAgent", etc.)
      TOOL_NAME_PREFIX = "WorkWith"

      class << self
        # Generate tool name for a delegate agent
        #
        # This is the single source of truth for delegation tool naming.
        # Used both when creating Delegate instances and when predicting tool names
        # for agent context setup.
        #
        # Converts names to PascalCase: backend → Backend, slack_agent → SlackAgent
        #
        # @param delegate_name [String, Symbol] Name of the delegate agent
        # @return [String] Tool name (e.g., "WorkWithBackend", "WorkWithSlackAgent")
        #
        # @example Simple name
        #   tool_name_for(:backend) # => "WorkWithBackend"
        #
        # @example Name with underscore
        #   tool_name_for(:slack_agent) # => "WorkWithSlackAgent"
        def tool_name_for(delegate_name)
          # Convert to PascalCase: split on underscore, capitalize each part, join
          pascal_case = delegate_name.to_s.split("_").map(&:capitalize).join
          "#{TOOL_NAME_PREFIX}#{pascal_case}"
        end
      end

      attr_reader :delegate_name, :delegate_target, :tool_name, :preserve_context, :delegate_chat

      # Initialize a delegation tool
      #
      # @param delegate_name [String] Name of the delegate agent (e.g., "backend")
      # @param delegate_description [String] Description of the delegate agent
      # @param delegate_chat [AgentChat, nil] The chat instance for the delegate agent (nil if delegating to swarm)
      # @param agent_name [Symbol, String] Name of the agent using this tool
      # @param swarm [Swarm] The swarm instance (provides hook_registry, swarm_registry)
      # @param delegating_chat [Agent::Chat, nil] The chat instance of the agent doing the delegating (for accessing hooks)
      # @param custom_tool_name [String, nil] Optional custom tool name (overrides auto-generated name)
      # @param preserve_context [Boolean] Whether to preserve conversation context between delegations (default: true)
      def initialize(
        delegate_name:,
        delegate_description:,
        delegate_chat:,
        agent_name:,
        swarm:,
        delegating_chat: nil,
        custom_tool_name: nil,
        preserve_context: true
      )
        super()

        @delegate_name = delegate_name
        @delegate_description = delegate_description
        @delegate_chat = delegate_chat
        @agent_name = agent_name
        @swarm = swarm
        @delegating_chat = delegating_chat
        @preserve_context = preserve_context

        # Use custom tool name if provided, otherwise generate using canonical method
        @tool_name = custom_tool_name || self.class.tool_name_for(delegate_name)
        @delegate_target = delegate_name.to_s

        # Track concurrent delegations to this target.
        # When multiple parallel tool calls target the same delegate, only the first
        # preserves context; subsequent concurrent calls always clear context to
        # prevent cross-contamination between independent parallel work.
        #
        # No Mutex needed: Async Fibers run on a single thread and only switch at
        # explicit yield points (IO, sleep, semaphore.acquire). Integer increment
        # and decrement never yield, so they are inherently atomic.
        @active_count = 0
      end

      # Override description to return dynamic string based on delegate
      def description
        "Work with #{@delegate_name} to delegate work, ask questions, or collaborate. #{@delegate_description}"
      end

      param :message,
        type: "string",
        desc: "Message to send to the agent - can be a work request, question, or collaboration message",
        required: true

      param :reset_context,
        type: "boolean",
        desc: "Reset the agent's conversation history before sending the message. Use it to recover from 'prompt too long' errors or other 4XX errors.",
        required: false

      # Override name to return custom delegation tool name
      def name
        @tool_name
      end

      # Check if this delegate uses lazy loading
      #
      # @return [Boolean] True if delegate is lazy-loaded
      def lazy?
        @delegate_chat.is_a?(Swarm::LazyDelegateChat)
      end

      # Check if this delegate has been initialized
      #
      # @return [Boolean] True if delegate chat is ready (either eager or lazy-initialized)
      def initialized?
        return true unless lazy?

        @delegate_chat.initialized?
      end

      # Force initialization of lazy delegate
      #
      # If the delegate is lazy-loaded, this will trigger immediate initialization.
      # For eager delegates, this is a no-op.
      #
      # @return [Agent::Chat] The resolved chat instance
      def initialize_delegate!
        resolve_delegate_chat
      end

      # Execute delegation with pre/post hooks
      #
      # Uses Fiber-local path tracking for circular dependency detection.
      # Each concurrent delegation runs in its own Fiber (via Async), so the path
      # is isolated per execution path. This correctly distinguishes parallel fan-out
      # (A→B, A→B) from true circular dependencies (A→B→A).
      #
      # @param message [String] Message to send to the agent
      # @param reset_context [Boolean] Whether to reset the agent's conversation history before delegation
      # @return [String] Result from delegate agent or error message
      def execute(message:, reset_context: false)
        # Save the current delegation path so we can restore it after execution.
        # The extended path (with our target) is only needed during chat.ask() so
        # child Fibers (nested delegations) inherit it. After delegation returns,
        # this Fiber's path should be unchanged.
        saved_delegation_path = Fiber[:delegation_path]

        # Access swarm infrastructure
        hook_registry = @swarm.hook_registry
        swarm_registry = @swarm.swarm_registry

        # Check for circular dependency using Fiber-local path
        # Each Fiber inherits the parent's path, so nested delegations
        # accumulate the full chain while parallel siblings remain isolated
        delegation_path = saved_delegation_path || []
        if delegation_path.include?(@delegate_target)
          emit_circular_warning(delegation_path)
          return "Error: Circular delegation detected: #{delegation_path.join(" -> ")} -> #{@delegate_target}. " \
            "Please restructure your delegation to avoid infinite loops."
        end

        # Get agent-specific hooks from the delegating chat instance
        agent_hooks = if @delegating_chat&.respond_to?(:hook_agent_hooks)
          @delegating_chat.hook_agent_hooks || {}
        else
          {}
        end

        # Trigger pre_delegation callback
        context = Hooks::Context.new(
          event: :pre_delegation,
          agent_name: @agent_name,
          swarm: @swarm,
          delegation_target: @delegate_target,
          metadata: {
            tool_name: @tool_name,
            message: message,
            timestamp: Time.now.utc.iso8601,
          },
        )

        executor = Hooks::Executor.new(hook_registry, logger: RubyLLM.logger)
        pre_agent_hooks = agent_hooks[:pre_delegation] || []
        result = executor.execute_safe(event: :pre_delegation, context: context, callbacks: pre_agent_hooks)

        # Check if callback halted or replaced the delegation
        if result.halt?
          return result.value || "Delegation halted by callback"
        elsif result.replace?
          return result.value
        end

        # Determine delegation type and proceed
        delegation_result = if @delegate_chat
          # Delegate to agent
          delegate_to_agent(message, reset_context: reset_context)
        elsif swarm_registry&.registered?(@delegate_target)
          # Delegate to registered swarm
          delegate_to_swarm(message, swarm_registry, reset_context: reset_context)
        else
          raise ConfigurationError, "Unknown delegation target: #{@delegate_target}"
        end

        # Trigger post_delegation callback
        post_context = Hooks::Context.new(
          event: :post_delegation,
          agent_name: @agent_name,
          swarm: @swarm,
          delegation_target: @delegate_target,
          delegation_result: delegation_result,
          metadata: {
            tool_name: @tool_name,
            message: message,
            result: delegation_result,
            timestamp: Time.now.utc.iso8601,
          },
        )

        post_agent_hooks = agent_hooks[:post_delegation] || []
        post_result = executor.execute_safe(event: :post_delegation, context: post_context, callbacks: post_agent_hooks)

        # Return modified result if callback replaces it
        if post_result.replace?
          post_result.value
        else
          delegation_result
        end
      rescue Faraday::TimeoutError, Net::ReadTimeout => e
        # Log timeout error as JSON event
        LogStream.emit(
          type: "delegation_error",
          agent: @agent_name,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          delegate_to: @tool_name,
          error_class: e.class.name,
          error_message: "Request timed out",
          error_backtrace: e.backtrace&.first(5) || [],
        )
        "Error: Request to #{@tool_name} timed out. The agent may be overloaded or the LLM service is not responding. Please try again or simplify the task."
      rescue Faraday::Error => e
        # Log network error as JSON event
        LogStream.emit(
          type: "delegation_error",
          agent: @agent_name,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          delegate_to: @tool_name,
          error_class: e.class.name,
          error_message: e.message,
          error_backtrace: e.backtrace&.first(5) || [],
        )
        "Error: Network error communicating with #{@tool_name}: #{e.class.name}. Please check connectivity and try again."
      rescue StandardError => e
        # Log unexpected error as JSON event
        backtrace_array = e.backtrace&.first(5) || []
        LogStream.emit(
          type: "delegation_error",
          agent: @agent_name,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          delegate_to: @tool_name,
          error_class: e.class.name,
          error_message: e.message,
          error_backtrace: backtrace_array,
        )
        # Return error string for LLM
        backtrace_str = backtrace_array.join("\n  ")
        "Error: #{@tool_name} encountered an error: #{e.class.name}: #{e.message}\nBacktrace:\n  #{backtrace_str}"
      ensure
        # Restore the calling Fiber's delegation path.
        # The extended path was only needed during chat.ask() so child Fibers
        # (spawned for nested tool calls) could inherit it for circular detection.
        Fiber[:delegation_path] = saved_delegation_path
      end

      private

      # Delegate to an agent
      #
      # Handles both eager Agent::Chat instances and lazy-loaded delegates.
      # LazyDelegateChat instances are initialized on first access.
      # Sets Fiber-local delegation path so child Fibers (nested delegations)
      # inherit the full chain for circular dependency detection.
      #
      # Tracks concurrent delegations to this target. When multiple parallel
      # tool calls target the same delegate (fan-out), only the first call
      # preserves context; subsequent concurrent calls always clear context
      # to prevent cross-contamination between independent parallel work.
      # Context clearing happens inside Agent::Chat's ask_semaphore for safety.
      #
      # @param message [String] Message to send to the agent
      # @param reset_context [Boolean] Whether to reset the agent's conversation history before delegation
      # @return [String] Result from agent
      def delegate_to_agent(message, reset_context: false)
        @active_count += 1
        concurrent = @active_count > 1

        # Set Fiber-local delegation path for this execution path
        # Child Fibers (from nested delegations) inherit this path automatically
        # We create a new array to avoid mutating the parent Fiber's reference
        Fiber[:delegation_path] = (Fiber[:delegation_path] || []) + [@delegate_target]

        # Resolve the chat instance (handles lazy loading)
        chat = resolve_delegate_chat

        # Determine if context should be cleared:
        # - reset_context: explicit caller request
        # - !preserve_context: agent configuration
        # - concurrent: parallel fan-out to same delegate (always isolate)
        # Clearing is done inside chat.ask's semaphore to avoid race conditions
        should_clear = reset_context || !@preserve_context || concurrent

        response = chat.ask(message, source: "delegation", clear_context: should_clear)
        response.content
      ensure
        @active_count -= 1
      end

      # Resolve the delegate chat instance
      #
      # If the delegate is a LazyDelegateChat, initializes it on first access.
      # Otherwise, returns the chat directly.
      #
      # @return [Agent::Chat] The resolved chat instance
      def resolve_delegate_chat
        if @delegate_chat.is_a?(Swarm::LazyDelegateChat)
          @delegate_chat.chat
        else
          @delegate_chat
        end
      end

      # Delegate to a registered swarm
      #
      # Sets Fiber-local delegation path so child Fibers (nested delegations)
      # inherit the full chain for circular dependency detection.
      # Tracks concurrent delegations the same way as delegate_to_agent.
      #
      # @param message [String] Message to send to the swarm
      # @param swarm_registry [SwarmRegistry] Registry for sub-swarms
      # @param reset_context [Boolean] Whether to reset the swarm's conversation history before delegation
      # @return [String] Result from swarm's lead agent
      def delegate_to_swarm(message, swarm_registry, reset_context: false)
        @active_count += 1
        concurrent = @active_count > 1

        # Set Fiber-local delegation path for this execution path
        Fiber[:delegation_path] = (Fiber[:delegation_path] || []) + [@delegate_target]

        # Load sub-swarm (lazy load + cache)
        subswarm = swarm_registry.load_swarm(@delegate_target)

        # Reset swarm context if explicitly requested or concurrent fan-out
        swarm_registry.reset(@delegate_target) if reset_context || concurrent

        # Execute sub-swarm's lead agent (uses agent() to trigger lazy initialization)
        lead_agent = subswarm.agent(subswarm.lead_agent)
        response = lead_agent.ask(message, source: "delegation")
        result = response.content

        # Reset if keep_context: false (standard behavior)
        swarm_registry.reset_if_needed(@delegate_target)

        result
      ensure
        @active_count -= 1
      end

      # Emit circular dependency warning event
      #
      # @param delegation_path [Array<String>] Current Fiber-local delegation path
      # @return [void]
      def emit_circular_warning(delegation_path)
        LogStream.emit(
          type: "delegation_circular_dependency",
          agent: @agent_name,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          target: @delegate_target,
          delegation_path: delegation_path,
          timestamp: Time.now.utc.iso8601,
        )
      end
    end
  end
end
