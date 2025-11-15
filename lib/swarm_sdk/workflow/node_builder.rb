# frozen_string_literal: true

module SwarmSDK
  class Workflow
    # NodeBuilder provides DSL for configuring individual nodes within a workflow
    #
    # A node represents a stage in a multi-step workflow where a specific set
    # of agents collaborate. Each node creates an independent swarm execution.
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
    #
    #     depends_on :planning
    #   end
    class NodeBuilder
      attr_reader :name,
        :agent_configs,
        :dependencies,
        :lead_override,
        :input_transformer,
        :output_transformer,
        :input_transformer_command,
        :output_transformer_command

      def initialize(name)
        @name = name
        @agent_configs = []
        @dependencies = []
        @lead_override = nil
        @input_transformer = nil # Ruby block
        @output_transformer = nil # Ruby block
        @input_transformer_command = nil # Bash command
        @output_transformer_command = nil # Bash command
      end

      # Configure an agent for this node
      #
      # Returns an AgentConfig object that supports fluent delegation and tool override syntax.
      # If delegates_to/tools are not called, the agent uses global configuration.
      #
      # By default, agents get fresh context in each node (reset_context: true).
      # Set reset_context: false to preserve conversation history across nodes.
      #
      # @param name [Symbol] Agent name
      # @param reset_context [Boolean] Whether to reset agent context (default: true)
      # @return [AgentConfig] Fluent configuration object
      #
      # @example With delegation
      #   agent(:backend).delegates_to(:tester, :database)
      #
      # @example Without delegation
      #   agent(:planner)
      #
      # @example Preserve context across nodes
      #   agent(:architect, reset_context: false)
      #
      # @example Override tools for this node
      #   agent(:backend).tools(:Read, :Think)
      #
      # @example Combine delegation and tools
      #   agent(:backend).delegates_to(:tester).tools(:Read, :Edit, :Write)
      def agent(name, reset_context: true)
        config = AgentConfig.new(name, self, reset_context: reset_context)

        # Register immediately with empty delegation and no tool override
        # If delegates_to/tools are called later, they will update this
        register_agent(name, [], reset_context, nil)

        config
      end

      # Register an agent configuration (called by AgentConfig)
      #
      # @param agent_name [Symbol] Agent name
      # @param delegates_to [Array<Symbol>] Delegation targets
      # @param reset_context [Boolean] Whether to reset agent context
      # @param tools [Array<Symbol>, nil] Tool override for this node (nil = use global)
      # @return [void]
      def register_agent(agent_name, delegates_to, reset_context = true, tools = nil)
        # Check if agent already registered
        existing = @agent_configs.find { |ac| ac[:agent] == agent_name }

        if existing
          # Update delegation, reset_context, and tools (happens when methods are called after agent())
          existing[:delegates_to] = delegates_to
          existing[:reset_context] = reset_context
          existing[:tools] = tools unless tools.nil?
        else
          # Add new agent configuration
          @agent_configs << {
            agent: agent_name,
            delegates_to: delegates_to,
            reset_context: reset_context,
            tools: tools,
          }
        end
      end

      # Declare dependencies (nodes that must execute before this one)
      #
      # @param node_names [Array<Symbol>] Names of prerequisite nodes
      # @return [void]
      #
      # @example Single dependency
      #   depends_on :planning
      #
      # @example Multiple dependencies
      #   depends_on :frontend, :backend
      def depends_on(*node_names)
        @dependencies.concat(node_names.map(&:to_sym))
      end

      # Override the lead agent (first agent is lead by default)
      #
      # @param agent_name [Symbol] Name of agent to make lead
      # @return [void]
      #
      # @example
      #   agent(:backend).delegates_to(:tester)
      #   agent(:tester)
      #   lead :tester  # tester is lead instead of backend
      def lead(agent_name)
        @lead_override = agent_name.to_sym
      end

      # Define input transformer for this node
      #
      # The transformer receives a NodeContext object with access to:
      # - Previous node's result (convenience: ctx.content)
      # - Original user prompt (ctx.original_prompt)
      # - All previous node results (ctx.all_results[:node_name])
      # - Current node metadata (ctx.node_name, ctx.dependencies)
      #
      # Can also be used for side effects (logging, file I/O) since the block
      # runs at execution time, not declaration time.
      #
      # **Control Flow**: Return a hash with special keys to control execution:
      # - `skip_execution: true` - Skip node's LLM execution, return content immediately
      # - `halt_workflow: true` - Halt entire workflow with content as final result
      # - `goto_node: :node_name` - Jump to different node with content as input
      #
      # @yield [NodeContext] Context with previous results and metadata
      # @return [String, Hash] Transformed input OR control hash
      #
      # @example Access previous result and original prompt
      #   input do |ctx|
      #     # Convenience accessor
      #     previous_content = ctx.content
      #
      #     # Access original prompt
      #     "Original: #{ctx.original_prompt}\nPrevious: #{previous_content}"
      #   end
      #
      # @example Access results from specific nodes
      #   input do |ctx|
      #     plan = ctx.all_results[:planning].content
      #     design = ctx.all_results[:design].content
      #
      #     "Implement based on:\nPlan: #{plan}\nDesign: #{design}"
      #   end
      #
      # @example Skip execution (caching) - using return
      #   input do |ctx|
      #     cached = check_cache(ctx.content)
      #     return ctx.skip_execution(content: cached) if cached
      #     ctx.content
      #   end
      #
      # @example Halt workflow (validation) - using return
      #   input do |ctx|
      #     if ctx.content.length > 10000
      #       # Halt entire workflow - return works safely!
      #       return ctx.halt_workflow(content: "ERROR: Input too long")
      #     end
      #     ctx.content
      #   end
      #
      # @example Jump to different node (conditional routing) - using return
      #   input do |ctx|
      #     if ctx.content.include?("NEEDS_REVIEW")
      #       # Jump to review node instead - return works safely!
      #       return ctx.goto_node(:review, content: ctx.content)
      #     end
      #     ctx.content
      #   end
      #
      # @note The input block is automatically converted to a lambda, which means
      #   return statements work safely and only exit the transformer, not the
      #   entire program. This allows natural control flow patterns.
      def input(&block)
        @input_transformer = ProcHelpers.to_lambda(block)
      end

      # Set input transformer as bash command (YAML API)
      #
      # The command receives NodeContext as JSON on STDIN and outputs transformed content.
      #
      # **Exit codes:**
      # - 0: Success, use STDOUT as transformed content
      # - 1: Skip node execution, use current_input unchanged (STDOUT ignored)
      # - 2: Halt workflow with error, show STDERR (STDOUT ignored)
      #
      # @param command [String] Bash command to execute
      # @param timeout [Integer] Timeout in seconds (default: 60)
      # @return [void]
      #
      # @example
      #   input_command("scripts/validate.sh", timeout: 30)
      def input_command(command, timeout: TransformerExecutor::DEFAULT_TIMEOUT)
        @input_transformer_command = { command: command, timeout: timeout }
      end

      # Define output transformer for this node
      #
      # The transformer receives a NodeContext object with access to:
      # - Current node's result (convenience: ctx.content)
      # - Original user prompt (ctx.original_prompt)
      # - All completed node results (ctx.all_results[:node_name])
      # - Current node metadata (ctx.node_name)
      #
      # Can also be used for side effects (logging, file I/O) since the block
      # runs at execution time, not declaration time.
      #
      # **Control Flow**: Return a hash with special keys to control execution:
      # - `halt_workflow: true` - Halt entire workflow with content as final result
      # - `goto_node: :node_name` - Jump to different node with content as input
      #
      # @yield [NodeContext] Context with current result and metadata
      # @return [String, Hash] Transformed output OR control hash
      #
      # @example Transform and save to file
      #   output do |ctx|
      #     # Side effect: save to file
      #     File.write("results/plan.txt", ctx.content)
      #
      #     # Return transformed output for next node
      #     "Key decisions: #{extract_decisions(ctx.content)}"
      #   end
      #
      # @example Access original prompt
      #   output do |ctx|
      #     # Include original context in output
      #     "Task: #{ctx.original_prompt}\nResult: #{ctx.content}"
      #   end
      #
      # @example Halt workflow (convergence check) - using return
      #   output do |ctx|
      #     return ctx.halt_workflow(content: ctx.content) if converged?(ctx.content)
      #     ctx.content
      #   end
      #
      # @example Jump to different node (conditional routing) - using return
      #   output do |ctx|
      #     if needs_revision?(ctx.content)
      #       # Go back to revision node - return works safely!
      #       return ctx.goto_node(:revision, content: ctx.content)
      #     end
      #     ctx.content
      #   end
      #
      # @note The output block is automatically converted to a lambda, which means
      #   return statements work safely and only exit the transformer, not the
      #   entire program. This allows natural control flow patterns.
      def output(&block)
        @output_transformer = ProcHelpers.to_lambda(block)
      end

      # Set output transformer as bash command (YAML API)
      #
      # The command receives NodeContext as JSON on STDIN and outputs transformed content.
      #
      # **Exit codes:**
      # - 0: Success, use STDOUT as transformed content
      # - 1: Pass through unchanged, use result.content (STDOUT ignored)
      # - 2: Halt workflow with error, show STDERR (STDOUT ignored)
      #
      # @param command [String] Bash command to execute
      # @param timeout [Integer] Timeout in seconds (default: 60)
      # @return [void]
      #
      # @example
      #   output_command("scripts/format.sh", timeout: 30)
      def output_command(command, timeout: TransformerExecutor::DEFAULT_TIMEOUT)
        @output_transformer_command = { command: command, timeout: timeout }
      end

      # Check if node has any input transformer (block or command)
      #
      # @return [Boolean]
      def has_input_transformer?
        @input_transformer || @input_transformer_command
      end

      # Check if node has any output transformer (block or command)
      #
      # @return [Boolean]
      def has_output_transformer?
        @output_transformer || @output_transformer_command
      end

      # Transform input using configured transformer (block or command)
      #
      # Executes either Ruby block or bash command transformer.
      #
      # **Ruby block return values:**
      # - String: Transformed content
      # - Hash with `skip_execution: true`: Skip node execution
      # - Hash with `halt_workflow: true`: Halt entire workflow
      # - Hash with `goto_node: :name`: Jump to different node
      #
      # **Exit code behavior (bash commands only):**
      # - Exit 0: Use STDOUT as transformed content
      # - Exit 1: Skip node execution, use current_input unchanged (STDOUT ignored)
      # - Exit 2: Halt workflow with error (STDOUT ignored)
      #
      # @param context [NodeContext] Context with previous results and metadata
      # @param current_input [String] Fallback content for exit 1 (skip), also used for halt error context
      # @return [String, Hash] Transformed input OR control hash (skip_execution, halt_workflow, goto_node)
      # @raise [ConfigurationError] If bash transformer halts workflow (exit 2)
      def transform_input(context, current_input:)
        # No transformer configured: return content as-is
        return context.content unless @input_transformer || @input_transformer_command

        # Ruby block transformer
        # Ruby blocks can return String (transformed content) OR Hash (control flow)
        if @input_transformer
          result = @input_transformer.call(context)

          # If hash, validate control flow keys
          if result.is_a?(Hash)
            validate_transformer_hash(result, :input)
          end

          return result
        end

        # Bash command transformer
        # Bash commands use exit codes to control behavior:
        # - Exit 0: Success, use STDOUT as transformed content
        # - Exit 1: Skip node execution, use current_input unchanged (STDOUT ignored)
        # - Exit 2: Halt workflow with error (STDOUT ignored)
        if @input_transformer_command
          result = TransformerExecutor.execute(
            command: @input_transformer_command[:command],
            context: context,
            event: "input",
            node_name: @name,
            fallback_content: current_input, # Used for exit 1 (skip)
            timeout: @input_transformer_command[:timeout],
          )

          # Handle transformer result based on exit code
          if result.halt?
            # Exit 2: Halt workflow with error
            raise ConfigurationError,
              "Input transformer halted workflow for node '#{@name}': #{result.error_message}"
          elsif result.skip_execution?
            # Exit 1: Skip node execution, return skip hash
            # Content is current_input unchanged (STDOUT was ignored)
            { skip_execution: true, content: result.content }
          else
            # Exit 0: Return transformed content from STDOUT
            result.content
          end
        end
      end

      # Transform output using configured transformer (block or command)
      #
      # Executes either Ruby block or bash command transformer.
      #
      # **Ruby block return values:**
      # - String: Transformed content
      # - Hash with `halt_workflow: true`: Halt entire workflow
      # - Hash with `goto_node: :name`: Jump to different node
      #
      # **Exit code behavior (bash commands only):**
      # - Exit 0: Use STDOUT as transformed content
      # - Exit 1: Pass through unchanged, use result.content (STDOUT ignored)
      # - Exit 2: Halt workflow with error (STDOUT ignored)
      #
      # @param context [NodeContext] Context with current result and metadata
      # @return [String, Hash] Transformed output OR control hash (halt_workflow, goto_node)
      # @raise [ConfigurationError] If bash transformer halts workflow (exit 2)
      def transform_output(context)
        # No transformer configured: return content as-is
        return context.content unless @output_transformer || @output_transformer_command

        # Ruby block transformer
        # Ruby blocks can return String (transformed content) OR Hash (control flow)
        if @output_transformer
          result = @output_transformer.call(context)

          # If hash, validate control flow keys
          if result.is_a?(Hash)
            validate_transformer_hash(result, :output)
          end

          return result
        end

        # Bash command transformer
        # Bash commands use exit codes to control behavior:
        # - Exit 0: Success, use STDOUT as transformed content
        # - Exit 1: Pass through unchanged, use result.content (STDOUT ignored)
        # - Exit 2: Halt workflow with error from STDERR (STDOUT ignored)
        if @output_transformer_command
          result = TransformerExecutor.execute(
            command: @output_transformer_command[:command],
            context: context,
            event: "output",
            node_name: @name,
            fallback_content: context.content, # result.content for exit 1
            timeout: @output_transformer_command[:timeout],
          )

          # Handle transformer result based on exit code
          if result.halt?
            # Exit 2: Halt workflow with error
            raise ConfigurationError,
              "Output transformer halted workflow for node '#{@name}': #{result.error_message}"
          else
            # Exit 0: Return transformed content from STDOUT
            # Exit 1: Return fallback (result.content unchanged)
            result.content
          end
        end
      end

      # Get the lead agent for this node
      #
      # @return [Symbol] Lead agent name
      def lead_agent
        @lead_override || @agent_configs.first&.dig(:agent)
      end

      # Check if this is an agent-less (computation-only) node
      #
      # Agent-less nodes run pure Ruby code without LLM execution.
      # They must have at least one transformer (input or output).
      #
      # @return [Boolean]
      def agent_less?
        @agent_configs.empty?
      end

      # Validate node configuration
      #
      # Also auto-adds agents that are referenced in delegates_to but not explicitly declared.
      # This allows writing: agent(:backend).delegates_to(:verifier)
      # without needing: agent(:verifier)
      #
      # @return [void]
      # @raise [ConfigurationError] If configuration is invalid
      def validate!
        # Auto-add agents mentioned in delegates_to but not explicitly declared
        auto_add_delegate_agents

        # Agent-less nodes (pure computation) are allowed but need transformers
        if @agent_configs.empty?
          unless has_input_transformer? || has_output_transformer?
            raise ConfigurationError,
              "Agent-less node '#{@name}' must have at least one transformer (input or output). " \
                "Either add agents with agent(:name) or add input/output transformers."
          end
        end

        # If has agents, validate lead override
        if @lead_override && !@agent_configs.any? { |ac| ac[:agent] == @lead_override }
          raise ConfigurationError,
            "Node '#{@name}' lead agent '#{@lead_override}' not found in node's agents"
        end
      end

      private

      # Validate transformer hash return value
      #
      # Ensures hash has valid control flow keys and required content field.
      #
      # @param hash [Hash] Hash returned from transformer
      # @param transformer_type [Symbol] :input or :output
      # @return [void]
      # @raise [ConfigurationError] If hash is invalid
      def validate_transformer_hash(hash, transformer_type)
        # Valid control keys
        valid_keys = if transformer_type == :input
          [:skip_execution, :halt_workflow, :goto_node, :content]
        else
          [:halt_workflow, :goto_node, :content]
        end

        # Check for invalid keys
        invalid_keys = hash.keys - valid_keys
        if invalid_keys.any?
          raise ConfigurationError,
            "Invalid #{transformer_type} transformer hash keys: #{invalid_keys.join(", ")}. " \
              "Valid keys: #{valid_keys.join(", ")}"
        end

        # Ensure content is present
        unless hash.key?(:content)
          raise ConfigurationError,
            "#{transformer_type.capitalize} transformer hash must include :content key"
        end

        # Ensure only one control key
        control_keys = hash.keys & [:skip_execution, :halt_workflow, :goto_node]
        if control_keys.size > 1
          raise ConfigurationError,
            "#{transformer_type.capitalize} transformer hash can only have one control key, got: #{control_keys.join(", ")}"
        end

        # Validate goto_node has valid node name
        if hash[:goto_node] && !hash[:goto_node].is_a?(Symbol)
          raise ConfigurationError,
            "goto_node value must be a Symbol, got: #{hash[:goto_node].class}"
        end
      end

      # Auto-add agents that are mentioned in delegates_to but not explicitly declared
      #
      # This allows:
      #   agent(:backend).delegates_to(:tester)
      # Without needing:
      #   agent(:tester)
      #
      # The tester agent is automatically added to the node with no delegation
      # and reset_context: true (fresh context by default).
      #
      # @return [void]
      def auto_add_delegate_agents
        # Collect all agents mentioned in delegates_to
        all_delegates = @agent_configs.flat_map { |ac| ac[:delegates_to] }.uniq

        # Find delegates that aren't explicitly declared
        declared_agents = @agent_configs.map { |ac| ac[:agent] }
        missing_delegates = all_delegates - declared_agents

        # Auto-add missing delegates with empty delegation and default reset_context
        missing_delegates.each do |delegate_name|
          @agent_configs << { agent: delegate_name, delegates_to: [], reset_context: true }
        end
      end
    end
  end
end
