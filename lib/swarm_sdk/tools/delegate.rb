# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Delegate tool for working with other agents in the swarm
    #
    # Creates agent-specific collaboration tools (e.g., WorkWithBackend)
    # that allow one agent to work with another agent.
    # Supports pre/post delegation hooks for customization.
    class Delegate < RubyLLM::Tool
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
        # @param delegate_name [String, Symbol] Name of the delegate agent
        # @return [String] Tool name (e.g., "WorkWithBackend")
        def tool_name_for(delegate_name)
          "#{TOOL_NAME_PREFIX}#{delegate_name.to_s.capitalize}"
        end
      end

      attr_reader :delegate_name, :delegate_target, :tool_name

      # Initialize a delegation tool
      #
      # @param delegate_name [String] Name of the delegate agent (e.g., "backend")
      # @param delegate_description [String] Description of the delegate agent
      # @param delegate_chat [AgentChat, nil] The chat instance for the delegate agent (nil if delegating to swarm)
      # @param agent_name [Symbol, String] Name of the agent using this tool
      # @param swarm [Swarm] The swarm instance (provides hook_registry, delegation_call_stack, swarm_registry)
      # @param delegating_chat [Agent::Chat, nil] The chat instance of the agent doing the delegating (for accessing hooks)
      def initialize(
        delegate_name:,
        delegate_description:,
        delegate_chat:,
        agent_name:,
        swarm:,
        delegating_chat: nil
      )
        super()

        @delegate_name = delegate_name
        @delegate_description = delegate_description
        @delegate_chat = delegate_chat
        @agent_name = agent_name
        @swarm = swarm
        @delegating_chat = delegating_chat

        # Generate tool name using canonical method
        @tool_name = self.class.tool_name_for(delegate_name)
        @delegate_target = delegate_name.to_s
      end

      # Override description to return dynamic string based on delegate
      def description
        "Work with #{@delegate_name} to delegate work, ask questions, or collaborate. #{@delegate_description}"
      end

      param :message,
        type: "string",
        desc: "Message to send to the agent - can be a work request, question, or collaboration message",
        required: true

      # Override name to return custom delegation tool name
      def name
        @tool_name
      end

      # Execute delegation with pre/post hooks
      #
      # @param message [String] Message to send to the agent
      # @return [String] Result from delegate agent or error message
      def execute(message:)
        # Access swarm infrastructure
        call_stack = @swarm.delegation_call_stack
        hook_registry = @swarm.hook_registry
        swarm_registry = @swarm.swarm_registry

        # Check for circular dependency
        if call_stack.include?(@delegate_target)
          emit_circular_warning(call_stack)
          return "Error: Circular delegation detected: #{call_stack.join(" -> ")} -> #{@delegate_target}. " \
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
          delegate_to_agent(message, call_stack)
        elsif swarm_registry&.registered?(@delegate_target)
          # Delegate to registered swarm
          delegate_to_swarm(message, call_stack, swarm_registry)
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
      end

      private

      # Delegate to an agent
      #
      # @param message [String] Message to send to the agent
      # @param call_stack [Array] Delegation call stack for circular dependency detection
      # @return [String] Result from agent
      def delegate_to_agent(message, call_stack)
        # Push delegate target onto call stack to track delegation chain
        call_stack.push(@delegate_target)
        begin
          response = @delegate_chat.ask(message, source: "delegation")
          response.content
        ensure
          # Always pop from stack, even if delegation fails
          call_stack.pop
        end
      end

      # Delegate to a registered swarm
      #
      # @param message [String] Message to send to the swarm
      # @param call_stack [Array] Delegation call stack for circular dependency detection
      # @param swarm_registry [SwarmRegistry] Registry for sub-swarms
      # @return [String] Result from swarm's lead agent
      def delegate_to_swarm(message, call_stack, swarm_registry)
        # Load sub-swarm (lazy load + cache)
        subswarm = swarm_registry.load_swarm(@delegate_target)

        # Push delegate target onto call stack to track delegation chain
        call_stack.push(@delegate_target)
        begin
          # Execute sub-swarm's lead agent
          lead_agent = subswarm.agents[subswarm.lead_agent]
          response = lead_agent.ask(message, source: "delegation")
          result = response.content

          # Reset if keep_context: false
          swarm_registry.reset_if_needed(@delegate_target)

          result
        ensure
          # Always pop from stack, even if delegation fails
          call_stack.pop
        end
      end

      # Emit circular dependency warning event
      #
      # @param call_stack [Array] Current delegation call stack
      # @return [void]
      def emit_circular_warning(call_stack)
        LogStream.emit(
          type: "delegation_circular_dependency",
          agent: @agent_name,
          swarm_id: @swarm.swarm_id,
          parent_swarm_id: @swarm.parent_swarm_id,
          target: @delegate_target,
          call_stack: call_stack,
          timestamp: Time.now.utc.iso8601,
        )
      end
    end
  end
end
