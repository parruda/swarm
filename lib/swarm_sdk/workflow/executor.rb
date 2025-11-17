# frozen_string_literal: true

module SwarmSDK
  class Workflow
    # Handles workflow execution orchestration
    #
    # Extracted from Workflow#execute to reduce complexity and improve maintainability.
    # Orchestrates node execution, transformer handling, and control flow.
    #
    # @example
    #   executor = Executor.new(workflow)
    #   result = executor.run("Build auth system") { |entry| puts entry }
    class Executor
      # Execution state container
      #
      # Holds mutable state during workflow execution to avoid instance variable pollution.
      ExecutionState = Struct.new(
        :current_input,
        :results,
        :last_result,
        :execution_index,
        :logs,
        keyword_init: true,
      )

      # Output transformer context container
      #
      # Groups parameters for output transformer processing to avoid long parameter lists.
      OutputTransformerContext = Struct.new(
        :node,
        :node_name,
        :node_start_time,
        :state,
        :result,
        :skip_execution,
        keyword_init: true,
      )

      def initialize(workflow)
        @workflow = workflow
      end

      # Execute the workflow with a prompt
      #
      # @param prompt [String] Initial prompt for the workflow
      # @param inherit_subscriptions [Boolean] Whether to inherit parent log subscriptions
      # @yield [Hash] Log entry if block given (for streaming)
      # @return [Result] Final result from last node execution
      def run(prompt, inherit_subscriptions: true, &block)
        @parent_subscriptions = capture_parent_subscriptions if inherit_subscriptions
        setup_logging(inherit_subscriptions: inherit_subscriptions, &block)
        setup_fiber_context
        @workflow.original_prompt = prompt

        state = ExecutionState.new(
          current_input: prompt,
          results: {},
          last_result: nil,
          execution_index: 0,
          logs: [],
        )

        execute_nodes(state)
      ensure
        cleanup_fiber_context
        reset_logging
      end

      private

      # Capture parent subscriptions before overwriting Fiber storage
      #
      # @return [Array<LogCollector::Subscription>] Parent subscriptions
      def capture_parent_subscriptions
        Fiber[:log_subscriptions] || []
      end

      # Setup logging infrastructure if block given
      #
      # @param inherit_subscriptions [Boolean] Whether to inherit parent subscriptions
      # @yield [Hash] Log entry for streaming
      # @return [void]
      def setup_logging(inherit_subscriptions: true, &block)
        @has_logging = block_given?
        return unless @has_logging

        Fiber[:log_subscriptions] = if inherit_subscriptions && @parent_subscriptions
          # Keep parent subscriptions and add new one
          @parent_subscriptions.dup
        else
          # Isolate: start with fresh subscriptions
          []
        end

        LogCollector.subscribe do |entry|
          block.call(entry)
        end
        LogStream.emitter = LogCollector
      end

      # Setup fiber-local execution context
      #
      # @return [void]
      def setup_fiber_context
        Fiber[:execution_id] = generate_execution_id
      end

      # Cleanup fiber-local storage
      #
      # @return [void]
      def cleanup_fiber_context
        Fiber[:execution_id] = nil
        Fiber[:swarm_id] = nil
        Fiber[:parent_swarm_id] = nil
        Fiber[:log_subscriptions] = nil
      end

      # Reset logging state
      #
      # @return [void]
      def reset_logging
        return unless @has_logging

        LogCollector.reset!
        LogStream.reset!
      end

      # Generate unique execution ID for workflow
      #
      # @return [String] Generated execution ID
      def generate_execution_id
        "exec_workflow_#{SecureRandom.hex(8)}"
      end

      # Main node iteration loop with control flow support
      #
      # @param state [ExecutionState] Mutable execution state
      # @return [Result] Final result
      def execute_nodes(state)
        while state.execution_index < @workflow.execution_order.size
          control_action = execute_single_node(state)

          case control_action[:action]
          when :halt
            return control_action[:result]
          when :goto
            state.execution_index = find_node_index(control_action[:target])
            state.current_input = control_action[:content]
            next
          when :continue
            state.execution_index += 1
          end
        end

        state.last_result
      end

      # Execute a single node with full lifecycle
      #
      # @param state [ExecutionState] Mutable execution state
      # @return [Hash] Control action (:halt, :goto, or :continue)
      def execute_single_node(state)
        node_name = @workflow.execution_order[state.execution_index]
        node = @workflow.nodes[node_name]
        node_start_time = Time.now

        setup_node_fiber_context(node_name)
        emit_node_start(node_name, node)

        # Process input transformer (may modify current_input or return control flow)
        input_result = process_input_transformer(node, node_name, node_start_time, state)
        return input_result if input_result[:action] == :halt || input_result[:action] == :goto

        skip_execution = input_result[:skip]
        state.current_input = input_result[:content]

        # Execute node (or skip if requested)
        result = execute_node(node, node_name, state.current_input, skip_execution)
        state.results[node_name] = result
        state.last_result = result

        log_node_error(node_name, result) if result.error

        # Process output transformer (may return control flow)
        ctx = OutputTransformerContext.new(
          node: node,
          node_name: node_name,
          node_start_time: node_start_time,
          state: state,
          result: result,
          skip_execution: skip_execution,
        )
        output_result = process_output_transformer(ctx)

        case output_result[:action]
        when :halt
          return output_result
        when :goto
          emit_node_stop(node_name, node, result, Time.now - node_start_time, skip_execution)
          return output_result
        end

        state.current_input = output_result[:content]

        # Update result for agent-less nodes with transformed content
        update_agentless_result(node, node_name, state, result)

        emit_node_stop(node_name, node, result, Time.now - node_start_time, skip_execution)

        { action: :continue }
      end

      # Setup fiber-local context for node execution
      #
      # @param node_name [Symbol] Node name
      # @return [void]
      def setup_node_fiber_context(node_name)
        node_swarm_id = @workflow.swarm_id ? "#{@workflow.swarm_id}/node:#{node_name}" : nil
        Fiber[:swarm_id] = node_swarm_id
        Fiber[:parent_swarm_id] = @workflow.swarm_id
      end

      # Process input transformer and handle control flow
      #
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param node_name [Symbol] Node name
      # @param node_start_time [Time] When node started
      # @param state [ExecutionState] Current execution state
      # @return [Hash] Control action with :skip and :content keys
      def process_input_transformer(node, node_name, node_start_time, state)
        unless node.has_input_transformer?
          return { action: :continue, skip: false, content: state.current_input }
        end

        input_context = build_input_context(node, node_name, state)
        transformed = node.transform_input(input_context, current_input: state.current_input)

        handle_input_control_flow(transformed, node_name, node, node_start_time)
      end

      # Build NodeContext for input transformer
      #
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param node_name [Symbol] Node name
      # @param state [ExecutionState] Current execution state
      # @return [NodeContext] Context for transformer
      def build_input_context(node, node_name, state)
        previous_result = resolve_previous_result(node, state)

        NodeContext.for_input(
          previous_result: previous_result,
          all_results: state.results,
          original_prompt: @workflow.original_prompt,
          node_name: node_name,
          dependencies: node.dependencies,
          transformed_content: node.dependencies.size == 1 ? state.current_input : nil,
        )
      end

      # Resolve previous result based on dependencies
      #
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param state [ExecutionState] Current execution state
      # @return [Result, Hash, String] Previous result(s) or prompt
      def resolve_previous_result(node, state)
        case node.dependencies.size
        when 0
          state.current_input
        when 1
          state.results[node.dependencies.first]
        else
          node.dependencies.to_h { |dep| [dep, state.results[dep]] }
        end
      end

      # Handle control flow from input transformer
      #
      # @param transformed [String, Hash] Transformer result
      # @param node_name [Symbol] Node name
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param node_start_time [Time] When node started
      # @return [Hash] Control action
      def handle_input_control_flow(transformed, node_name, node, node_start_time)
        return { action: :continue, skip: false, content: transformed } unless transformed.is_a?(Hash)

        if transformed[:halt_workflow]
          halt_result = build_halt_result(transformed[:content], node_name, node_start_time)
          emit_node_stop(node_name, node, halt_result, Time.now - node_start_time, false)
          { action: :halt, result: halt_result }
        elsif transformed[:goto_node]
          { action: :goto, target: transformed[:goto_node], content: transformed[:content] }
        elsif transformed[:skip_execution]
          { action: :continue, skip: true, content: transformed[:content] }
        else
          { action: :continue, skip: false, content: transformed[:content] }
        end
      end

      # Execute the node (agent-less or with mini-swarm)
      #
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param node_name [Symbol] Node name
      # @param input [String] Input content
      # @param skip_execution [Boolean] Whether to skip execution
      # @return [Result] Execution result
      def execute_node(node, node_name, input, skip_execution)
        if skip_execution
          build_skip_result(node_name, input)
        elsif node.agent_less?
          execute_agent_less_node(node, input)
        else
          execute_swarm_node(node, input)
        end
      end

      # Build result for skipped execution
      #
      # @param node_name [Symbol] Node name
      # @param content [String] Content to include in result
      # @return [Result] Skip result
      def build_skip_result(node_name, content)
        Result.new(
          content: content,
          agent: "skipped:#{node_name}",
          logs: [],
          duration: 0.0,
        )
      end

      # Execute an agent-less (computation-only) node
      #
      # @param node [Workflow::NodeBuilder] Agent-less node configuration
      # @param input [String] Input content
      # @return [Result] Result with input passed through
      def execute_agent_less_node(node, input)
        Result.new(
          content: input,
          agent: "computation:#{node.name}",
          logs: [],
          duration: 0.0,
        )
      end

      # Execute node with mini-swarm
      #
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param input [String] Input content
      # @return [Result] Execution result
      def execute_swarm_node(node, input)
        mini_swarm = @workflow.build_swarm_for_node(node)
        result = mini_swarm.execute(input)
        @workflow.cache_agent_instances(mini_swarm, node)
        result
      end

      # Process output transformer and handle control flow
      #
      # @param ctx [OutputTransformerContext] Grouped transformer context
      # @return [Hash] Control action
      def process_output_transformer(ctx)
        output_context = NodeContext.for_output(
          result: ctx.result,
          all_results: ctx.state.results,
          original_prompt: @workflow.original_prompt,
          node_name: ctx.node_name,
        )
        transformed = ctx.node.transform_output(output_context)

        handle_output_control_flow(transformed, ctx)
      end

      # Handle control flow from output transformer
      #
      # @param transformed [String, Hash] Transformer result
      # @param ctx [OutputTransformerContext] Grouped transformer context
      # @return [Hash] Control action
      def handle_output_control_flow(transformed, ctx)
        return { action: :continue, content: transformed } unless transformed.is_a?(Hash)

        if transformed[:halt_workflow]
          halt_result = Result.new(
            content: transformed[:content],
            agent: ctx.result.agent,
            logs: ctx.result.logs,
            duration: ctx.result.duration,
          )
          emit_node_stop(ctx.node_name, ctx.node, halt_result, Time.now - ctx.node_start_time, ctx.skip_execution)
          { action: :halt, result: halt_result }
        elsif transformed[:goto_node]
          { action: :goto, target: transformed[:goto_node], content: transformed[:content] }
        else
          { action: :continue, content: transformed[:content] || transformed }
        end
      end

      # Update result for agent-less nodes with transformed content
      #
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param node_name [Symbol] Node name
      # @param state [ExecutionState] Current execution state
      # @param result [Result] Original result
      # @return [void]
      def update_agentless_result(node, node_name, state, result)
        return unless node.agent_less? && state.current_input != result.content

        updated_result = Result.new(
          content: state.current_input,
          agent: result.agent,
          logs: result.logs,
          duration: result.duration,
          error: result.error,
        )
        state.results[node_name] = updated_result
        state.last_result = updated_result
      end

      # Build result for halted workflow
      #
      # @param content [String] Content to include
      # @param node_name [Symbol] Node name
      # @param node_start_time [Time] When node started
      # @return [Result] Halt result
      def build_halt_result(content, node_name, node_start_time)
        Result.new(
          content: content,
          agent: "halted:#{node_name}",
          logs: [],
          duration: Time.now - node_start_time,
        )
      end

      # Log node execution error
      #
      # @param node_name [Symbol] Node name
      # @param result [Result] Execution result with error
      # @return [void]
      def log_node_error(node_name, result)
        RubyLLM.logger.error("Workflow: Node '#{node_name}' failed: #{result.error.message}")
        RubyLLM.logger.error("  Backtrace: #{result.error.backtrace&.first(5)&.join("\n  ")}")
      end

      # Find the index of a node in the execution order
      #
      # @param node_name [Symbol] Node name to find
      # @return [Integer] Index in execution order
      # @raise [ConfigurationError] If node not found
      def find_node_index(node_name)
        index = @workflow.execution_order.index(node_name)
        unless index
          raise ConfigurationError,
            "goto_node target '#{node_name}' not found. Available nodes: #{@workflow.execution_order.join(", ")}"
        end
        index
      end

      # Emit node_start event
      #
      # @param node_name [Symbol] Name of the node
      # @param node [Workflow::NodeBuilder] Node configuration
      # @return [void]
      def emit_node_start(node_name, node)
        return unless LogStream.emitter

        LogStream.emit(
          type: "node_start",
          node: node_name.to_s,
          agent_less: node.agent_less?,
          agents: node.agent_configs.map { |ac| ac[:agent].to_s },
          dependencies: node.dependencies.map(&:to_s),
          timestamp: Time.now.utc.iso8601,
        )
      end

      # Emit node_stop event
      #
      # @param node_name [Symbol] Name of the node
      # @param node [Workflow::NodeBuilder] Node configuration
      # @param result [Result] Node execution result
      # @param duration [Float] Node execution duration in seconds
      # @param skipped [Boolean] Whether execution was skipped
      # @return [void]
      def emit_node_stop(node_name, node, result, duration, skipped)
        return unless LogStream.emitter

        LogStream.emit(
          type: "node_stop",
          node: node_name.to_s,
          agent_less: node.agent_less?,
          skipped: skipped,
          agents: node.agent_configs.map { |ac| ac[:agent].to_s },
          duration: duration.round(3),
          timestamp: Time.now.utc.iso8601,
        )
      end
    end
  end
end
