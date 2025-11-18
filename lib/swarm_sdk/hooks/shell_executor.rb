# frozen_string_literal: true

require "open3"
require "json"
require "timeout"

module SwarmSDK
  module Hooks
    # Executes shell command hooks with JSON I/O and exit code handling
    #
    # ShellExecutor runs external shell commands (defined in YAML hooks) and
    # converts their exit codes to Result objects that control execution flow.
    #
    # ## Exit Code Behavior (following Claude Code convention)
    #
    # - **0**: Success - continue execution (Result.continue)
    # - **2**: Block with error feedback to LLM (Result.halt)
    # - **Other**: Non-blocking error - log warning and continue (Result.continue)
    #
    # ## JSON I/O Format
    #
    # **stdin (to hook script)**:
    # ```json
    # {
    #   "event": "pre_tool_use",
    #   "agent": "backend",
    #   "tool": "Write",
    #   "parameters": { "file_path": "api.rb", "content": "..." }
    # }
    # ```
    #
    # **stdout (from hook script)**:
    # ```json
    # {
    #   "success": false,
    #   "error": "Validation failed: syntax error"
    # }
    # ```
    #
    # @example Execute a validation hook
    #   result = SwarmSDK::Hooks::ShellExecutor.execute(
    #     command: "python scripts/validate.py",
    #     input_json: { event: "pre_tool_use", tool: "Write", parameters: {...} },
    #     timeout: 10,
    #     agent_name: :backend,
    #     swarm_name: "Dev Team"
    #   )
    #   # => Result (continue or halt based on exit code)
    class ShellExecutor
      # Backward compatibility alias - use Defaults module for new code
      DEFAULT_TIMEOUT = Defaults::Timeouts::HOOK_SHELL_SECONDS

      class << self
        # Execute a shell command hook
        #
        # @param command [String] Shell command to execute
        # @param input_json [Hash] JSON data to provide on stdin
        # @param timeout [Integer] Timeout in seconds (default: 60)
        # @param agent_name [Symbol, String, nil] Agent name for environment variables
        # @param swarm_name [String, nil] Swarm name for environment variables
        # @param event [Symbol] Event type for context-aware behavior
        # @return [Result] Result based on exit code (continue or halt)
        def execute(command:, input_json:, timeout: DEFAULT_TIMEOUT, agent_name: nil, swarm_name: nil, event: nil)
          # Build environment variables
          env = build_environment(agent_name: agent_name, swarm_name: swarm_name)

          # Execute command with JSON stdin and timeout
          stdout, stderr, status = Timeout.timeout(timeout) do
            Open3.capture3(
              env,
              command,
              stdin_data: JSON.generate(input_json),
            )
          end

          # Handle exit code per Claude Code convention (context-aware)
          result = handle_exit_code(status.exitstatus, stdout, stderr, event)

          # Emit log event for hook execution
          case status.exitstatus
          when 0
            # Success - log stdout/stderr
            emit_hook_log(
              event: event,
              agent_name: agent_name,
              command: command,
              exit_code: status.exitstatus,
              success: true,
              stdout: stdout,
              stderr: stderr,
            )
          when 2
            # Blocking error - always log stderr
            emit_hook_log(
              event: event,
              agent_name: agent_name,
              command: command,
              exit_code: status.exitstatus,
              success: false,
              stderr: stderr,
              blocked: true,
            )
          else
            # Non-blocking error - log stderr
            emit_hook_log(
              event: event,
              agent_name: agent_name,
              command: command,
              exit_code: status.exitstatus,
              success: false,
              stderr: stderr,
              blocked: false,
            )
          end

          result
        rescue Timeout::Error
          emit_hook_log(
            event: event,
            agent_name: agent_name,
            command: command,
            exit_code: nil,
            success: false,
            stderr: "Timeout after #{timeout}s",
          )
          # Don't block on timeout - log and continue
          Result.continue
        rescue StandardError => e
          emit_hook_log(
            event: event,
            agent_name: agent_name,
            command: command,
            exit_code: nil,
            success: false,
            stderr: e.message,
          )
          # Don't block on errors - log and continue
          Result.continue
        end

        private

        # Build environment variables for hook execution
        #
        # @param agent_name [Symbol, String, nil] Agent name
        # @param swarm_name [String, nil] Swarm name
        # @return [Hash] Environment variables
        def build_environment(agent_name:, swarm_name:)
          {
            "SWARM_SDK_PROJECT_DIR" => Dir.pwd,
            "SWARM_SDK_AGENT_NAME" => agent_name.to_s,
            "SWARM_SDK_SWARM_NAME" => swarm_name.to_s,
            "PATH" => ENV.fetch("PATH", ""),
          }
        end

        # Handle exit code and return appropriate Result
        #
        # @param exit_code [Integer] Process exit code
        # @param stdout [String] Standard output
        # @param stderr [String] Standard error
        # @param event [Symbol] Hook event type
        # @return [Result] Result based on exit code
        def handle_exit_code(exit_code, stdout, stderr, event)
          case exit_code
          when 0
            # Success - continue execution
            # For user_prompt and swarm_start: return stdout to be shown to agent
            if [:user_prompt, :swarm_start].include?(event) && !stdout.strip.empty?
              # Return Result with stdout that will be appended to prompt
              Result.replace(stdout.strip)
            else
              # Normal success
              Result.continue
            end
          when 2
            # Blocking error - behavior depends on event type
            handle_exit_code_2(event, stdout, stderr)
          else
            # Non-blocking error - continue (stderr logged above)
            Result.continue
          end
        end

        # Handle exit code 2 (blocking error)
        #
        # @param event [Symbol] Hook event type
        # @param _stdout [String] Standard output (unused)
        # @param stderr [String] Standard error
        # @return [Result] Result based on event type
        def handle_exit_code_2(event, _stdout, stderr)
          error_msg = stderr.strip

          case event
          when :pre_tool_use
            # Block tool call, show stderr to agent (stderr already logged above)
            Result.halt(error_msg)
          when :post_tool_use
            # Tool already ran, show stderr to agent (stderr already logged above)
            Result.halt(error_msg)
          when :user_prompt
            # Block prompt processing, erase prompt
            # stderr is logged (above) for user to see, but NOT shown to agent
            # Return empty halt (prompt is erased, no message to agent)
            Result.halt("")
          when :agent_stop
            # Block stoppage, show stderr to agent (stderr already logged above)
            Result.halt(error_msg)
          when :context_warning, :swarm_start, :swarm_stop
            # N/A - stderr logged above, don't halt
            Result.continue
          else
            # Default: halt with stderr
            Result.halt(error_msg)
          end
        end

        # Emit hook execution log entry
        #
        # @param event [Symbol] Hook event type
        # @param agent_name [String, Symbol, nil] Agent name
        # @param command [String] Shell command executed
        # @param exit_code [Integer, nil] Process exit code
        # @param success [Boolean] Whether execution succeeded
        # @param stdout [String, nil] Standard output
        # @param stderr [String, nil] Standard error
        # @param blocked [Boolean] Whether execution was blocked (exit code 2)
        def emit_hook_log(event:, agent_name:, command:, exit_code:, success:, stdout: nil, stderr: nil, blocked: false)
          # Only emit if LogStream is enabled (has emitter)
          return unless LogStream.enabled?

          log_entry = {
            type: "hook_executed",
            hook_event: event&.to_s, # Which hook event triggered this (pre_tool_use, swarm_start, etc.)
            agent: agent_name,
            command: command,
            exit_code: exit_code,
            success: success,
          }

          # Add stdout if present (exit code 0)
          log_entry[:stdout] = stdout.strip if stdout && !stdout.strip.empty?

          # Add stderr if present (any exit code)
          log_entry[:stderr] = stderr.strip if stderr && !stderr.strip.empty?

          # Add blocked flag for exit code 2
          log_entry[:blocked] = true if blocked

          LogStream.emit(**log_entry)
        end
      end
    end
  end
end
