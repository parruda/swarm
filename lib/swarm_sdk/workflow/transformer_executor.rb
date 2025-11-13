# frozen_string_literal: true

require "open3"
require "json"
require "timeout"

module SwarmSDK
  class Workflow
    # Executes bash command transformers for node input/output transformation
    #
    # Transformers are shell commands that receive NodeContext data on STDIN as JSON
    # and produce transformed content on STDOUT.
    #
    # ## Exit Code Behavior
    #
    # - **Exit 0**: Transform success
    #   - Use STDOUT as the transformed content
    #   - Node execution proceeds with transformed content
    #
    # - **Exit 1**: Skip node execution (pass-through)
    #   - STDOUT is IGNORED
    #   - Input transformer: Use current_input unchanged (no transformation)
    #   - Output transformer: Use result.content unchanged (no transformation)
    #   - For input transformer: Also skips the node's LLM execution
    #
    # - **Exit 2**: Halt entire workflow
    #   - STDOUT is IGNORED
    #   - STDERR is shown as error message
    #   - Workflow stops immediately with error
    #
    # ## JSON Input Format (STDIN)
    #
    # **Input transformer receives:**
    # ```json
    # {
    #   "event": "input",
    #   "node": "implementation",
    #   "original_prompt": "Build auth API",
    #   "content": "PLAN: Create endpoints...",
    #   "all_results": {
    #     "planning": {
    #       "content": "Create endpoints...",
    #       "agent": "planner",
    #       "duration": 2.5,
    #       "success": true
    #     }
    #   },
    #   "dependencies": ["planning"]
    # }
    # ```
    #
    # **Output transformer receives:**
    # ```json
    # {
    #   "event": "output",
    #   "node": "implementation",
    #   "original_prompt": "Build auth API",
    #   "content": "Implementation complete",
    #   "all_results": {
    #     "planning": {...},
    #     "implementation": {...}
    #   }
    # }
    # ```
    #
    # @example Input transformer that validates
    #   # validate.sh
    #   #!/bin/bash
    #   INPUT=$(cat)
    #   CONTENT=$(echo "$INPUT" | jq -r '.content')
    #
    #   if [ ${#CONTENT} -gt 10000 ]; then
    #     echo "Content too long" >&2
    #     exit 2  # Halt workflow
    #   fi
    #
    #   echo "$CONTENT"
    #   exit 0
    #
    # @example Input transformer that caches (skip execution)
    #   # cache_check.sh
    #   #!/bin/bash
    #   INPUT=$(cat)
    #   CONTENT=$(echo "$INPUT" | jq -r '.content')
    #
    #   if cached "$CONTENT"; then
    #     exit 1  # Skip node execution, pass through unchanged
    #   fi
    #
    #   echo "$CONTENT"
    #   exit 0
    class TransformerExecutor
      DEFAULT_TIMEOUT = 60

      # Result object for transformer execution
      TransformerResult = Struct.new(:success, :content, :skip_execution, :halt, :error_message, keyword_init: true) do
        def skip_execution?
          skip_execution
        end

        def halt?
          halt
        end
      end

      class << self
        # Execute a transformer shell command
        #
        # @param command [String] Shell command to execute
        # @param context [NodeContext] Node context for building JSON input
        # @param event [String] Event type ("input" or "output")
        # @param node_name [Symbol] Current node name
        # @param fallback_content [String] Content to use if skip (exit 1)
        # @param timeout [Integer] Timeout in seconds (default: 60)
        # @return [TransformerResult] Result with transformed content or skip/halt flags
        def execute(command:, context:, event:, node_name:, fallback_content:, timeout: DEFAULT_TIMEOUT)
          # Build JSON input for transformer
          input_json = build_transformer_input(context, event, node_name)

          # Build environment variables
          env = build_environment(node_name: node_name)

          # Execute command with JSON stdin and timeout
          stdout, stderr, status = Timeout.timeout(timeout) do
            Open3.capture3(
              env,
              command,
              stdin_data: JSON.generate(input_json),
            )
          end

          # Handle exit code
          # Exit 0: Transform success, use STDOUT
          # Exit 1: Skip node execution, use fallback_content (IGNORE STDOUT)
          # Exit 2: Halt workflow with error (IGNORE STDOUT)
          case status.exitstatus
          when 0
            # Success: use STDOUT as transformed content (strip trailing newline)
            TransformerResult.new(
              success: true,
              content: stdout.chomp, # Remove trailing newline from echo
              skip_execution: false,
              halt: false,
              error_message: nil,
            )
          when 1
            # Skip node execution: use fallback_content unchanged (IGNORE STDOUT)
            # For input transformer: skip_execution = true (skip LLM call)
            # For output transformer: skip_execution = false (just pass through)
            TransformerResult.new(
              success: true,
              content: fallback_content,
              skip_execution: (event == "input"), # Only skip LLM for input transformers
              halt: false,
              error_message: nil,
            )
          when 2
            # Halt workflow: return error (IGNORE STDOUT)
            error_msg = stderr.strip.empty? ? "Transformer halted workflow (exit 2)" : stderr.strip
            TransformerResult.new(
              success: false,
              content: nil,
              skip_execution: false,
              halt: true,
              error_message: error_msg,
            )
          else
            # Unknown exit code: treat as error (halt)
            error_msg = "Transformer exited with code #{status.exitstatus}\nSTDERR: #{stderr}"
            TransformerResult.new(
              success: false,
              content: nil,
              skip_execution: false,
              halt: true,
              error_message: error_msg,
            )
          end
        rescue Timeout::Error
          # Timeout: halt workflow
          TransformerResult.new(
            success: false,
            content: nil,
            skip_execution: false,
            halt: true,
            error_message: "Transformer command timed out after #{timeout}s",
          )
        rescue StandardError => e
          # Execution error: halt workflow
          TransformerResult.new(
            success: false,
            content: nil,
            skip_execution: false,
            halt: true,
            error_message: "Transformer command failed: #{e.message}",
          )
        end

        private

        # Build JSON input for transformer command
        #
        # @param context [NodeContext] Node context
        # @param event [String] Event type ("input" or "output")
        # @param node_name [Symbol] Node name
        # @return [Hash] JSON data to pass on stdin
        def build_transformer_input(context, event, node_name)
          base = {
            event: event,
            node: node_name.to_s,
            original_prompt: context.original_prompt,
            content: context.content,
          }

          # Add all_results (convert Result objects to hashes)
          if context.all_results && !context.all_results.empty?
            base[:all_results] = context.all_results.transform_values do |result|
              {
                content: result.content,
                agent: result.agent,
                duration: result.duration,
                success: result.success?,
              }
            end
          end

          # Add dependencies for input transformers
          if event == "input" && context.dependencies
            base[:dependencies] = context.dependencies.map(&:to_s)
          end

          base
        end

        # Build environment variables for transformer execution
        #
        # @param node_name [Symbol] Current node name
        # @return [Hash] Environment variables
        def build_environment(node_name:)
          {
            "SWARM_SDK_PROJECT_DIR" => Dir.pwd,
            "SWARM_SDK_NODE_NAME" => node_name.to_s,
            "PATH" => ENV.fetch("PATH", ""),
          }
        end
      end
    end
  end
end
