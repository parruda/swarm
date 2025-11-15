# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Bash tool for executing shell commands
    #
    # Executes commands in a persistent shell session with timeout support.
    # Provides comprehensive guidance on proper usage patterns.
    class Bash < RubyLLM::Tool
      def initialize(directory:)
        super()
        @directory = File.expand_path(directory)
      end

      def name
        "Bash"
      end

      description <<~DESC
        Executes a given bash command in a persistent shell session with optional timeout, ensuring proper handling and security measures.

        IMPORTANT: This tool is for terminal operations like git, npm, docker, etc. DO NOT use it for file operations (reading, writing, editing, searching, finding files) - use the specialized tools for this instead.

        Before executing the command, please follow these steps:

        1. Directory Verification:
           - If the command will create new directories or files, first use `ls` to verify the parent directory exists and is the correct location
           - For example, before running "mkdir foo/bar", first use `ls foo` to check that "foo" exists and is the intended parent directory

        2. Command Execution:
           - Always quote file paths that contain spaces with double quotes (e.g., cd "path with spaces/file.txt")
           - Examples of proper quoting:
             - cd "/Users/name/My Documents" (correct)
             - cd /Users/name/My Documents (incorrect - will fail)
             - python "/path/with spaces/script.py" (correct)
             - python /path/with spaces/script.py (incorrect - will fail)
           - After ensuring proper quoting, execute the command.
           - Capture the output of the command.

        Usage notes:
          - The command argument is required.
          - You can specify an optional timeout in milliseconds (up to 600000ms / 10 minutes). If not specified, commands will timeout after 120000ms (2 minutes).
          - It is very helpful if you write a clear, concise description of what this command does in 5-10 words.
          - If the output exceeds 30000 characters, output will be truncated before being returned to you.
          - Avoid using Bash with the `find`, `grep`, `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or when these commands are truly necessary for the task. Instead, always prefer using the dedicated tools for these commands:
            - File search: Use Glob (NOT find or ls)
            - Content search: Use Grep (NOT grep or rg)
            - Read files: Use Read (NOT cat/head/tail)
            - Edit files: Use Edit (NOT sed/awk)
            - Write files: Use Write (NOT echo >/cat <<EOF)
            - Communication: Output text directly (NOT echo/printf)
          - When issuing multiple commands:
            - If the commands are independent and can run in parallel, make multiple Bash tool calls in a single message. For example, if you need to run "git status" and "git diff", send a single message with two Bash tool calls in parallel.
            - If the commands depend on each other and must run sequentially, use a single Bash call with '&&' to chain them together (e.g., `git add . && git commit -m "message" && git push`). For instance, if one operation must complete before another starts (like mkdir before cp, Write before Bash for git operations, or git add before git commit), run these operations sequentially instead.
            - Use ';' only when you need to run commands sequentially but don't care if earlier commands fail
            - DO NOT use newlines to separate commands (newlines are ok in quoted strings)
          - Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of `cd`. You may use `cd` if the User explicitly requests it.
            <good-example>
            pytest /foo/bar/tests
            </good-example>
            <bad-example>
            cd /foo/bar && pytest tests
            </bad-example>
      DESC

      param :command,
        type: "string",
        desc: "The command to execute",
        required: true

      param :description,
        type: "string",
        desc: "Clear, concise description of what this command does in 5-10 words, in active voice. Examples:\nInput: ls\nOutput: List files in current directory\n\nInput: git status\nOutput: Show working tree status\n\nInput: npm install\nOutput: Install package dependencies\n\nInput: mkdir foo\nOutput: Create directory 'foo'",
        required: false

      param :timeout,
        type: "number",
        desc: "Optional timeout in milliseconds (max 600000)",
        required: false

      # Backward compatibility aliases - use Defaults module for new code
      DEFAULT_TIMEOUT_MS = Defaults::Timeouts::BASH_COMMAND_MS
      MAX_TIMEOUT_MS = Defaults::Timeouts::BASH_COMMAND_MAX_MS
      MAX_OUTPUT_LENGTH = Defaults::Limits::OUTPUT_CHARACTERS

      # Commands that are ALWAYS blocked for safety reasons
      # These cannot be overridden by permissions configuration
      ALWAYS_BLOCKED_COMMANDS = [
        %r{^rm\s+-rf\s+/$}, # rm -rf / - delete root filesystem
      ].freeze

      def execute(command:, description: nil, timeout: nil)
        # Validate inputs
        return validation_error("command is required") if command.nil? || command.empty?

        # Check against always-blocked commands
        blocked_pattern = ALWAYS_BLOCKED_COMMANDS.find { |pattern| pattern.match?(command) }
        if blocked_pattern
          return blocked_command_error(command, blocked_pattern)
        end

        # Validate and set timeout
        timeout_ms = timeout || DEFAULT_TIMEOUT_MS
        timeout_ms = [timeout_ms, MAX_TIMEOUT_MS].min
        timeout_seconds = timeout_ms / 1000.0

        # Execute command with timeout
        stdout = +""
        stderr = +""
        exit_status = nil

        begin
          require "open3"
          require "timeout"

          Timeout.timeout(timeout_seconds) do
            # CRITICAL: Change to agent's directory for subprocess
            # This is SAFE because Open3.popen3 creates a subprocess
            # The subprocess inherits the directory, but the parent fiber is unaffected
            Dir.chdir(@directory) do
              Open3.popen3(command) do |stdin, out, err, wait_thr|
                stdin.close # Close stdin since we don't send input

                # Read stdout and stderr
                stdout = out.read || ""
                stderr = err.read || ""
                exit_status = wait_thr.value.exitstatus
              end
            end
          end
        rescue Timeout::Error
          return format_timeout_error(command, timeout_seconds)
        rescue Errno::ENOENT => e
          return error("Command not found or executable not in PATH: #{e.message}")
        rescue Errno::EACCES
          return error("Permission denied: Cannot execute command '#{command}'")
        rescue StandardError => e
          return error("Failed to execute command: #{e.class.name} - #{e.message}")
        end

        # Build output
        output = format_command_output(command, description, stdout, stderr, exit_status)

        # Truncate if too long
        if output.length > MAX_OUTPUT_LENGTH
          truncated = output[0...MAX_OUTPUT_LENGTH]
          truncated += "\n\n<system-reminder>Output truncated at #{MAX_OUTPUT_LENGTH} characters. The full output was #{output.length} characters.</system-reminder>"
          output = truncated
        end

        # Add usage reminders for certain patterns
        output = add_usage_reminders(output, command)

        output
      rescue StandardError => e
        error("Unexpected error executing command: #{e.class.name} - #{e.message}")
      end

      private

      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end

      def error(message)
        "Error: #{message}"
      end

      def blocked_command_error(command, pattern)
        <<~ERROR
          Error: Command blocked for safety reasons.
          Command: #{command}
          Pattern: #{pattern.source}

          <system-reminder>
          SECURITY BLOCK: This command is permanently blocked for safety reasons and cannot be executed.

          This is a built-in safety feature of the Bash tool that cannot be overridden by any configuration.
          The command matches a pattern that could cause catastrophic system damage.

          DO NOT attempt to:
          - Modify the command slightly to bypass this check
          - Ask the user to allow this command
          - Work around this restriction in any way

          If you need to perform a similar operation safely, consider:
          - Using a more specific path instead of system-wide operations
          - Using dedicated tools for file operations
          - Asking the user for guidance on a safer approach

          This is an UNRECOVERABLE error. You must inform the user that this command cannot be executed for safety reasons.
          </system-reminder>
        ERROR
      end

      def format_timeout_error(command, timeout_seconds)
        <<~ERROR
          Error: Command timed out after #{timeout_seconds} seconds.
          Command: #{command}

          <system-reminder>The command exceeded the timeout limit. Consider:
          1. Breaking the command into smaller steps
          2. Increasing the timeout parameter
          3. Running long-running commands in the background if supported
          </system-reminder>
        ERROR
      end

      def format_command_output(command, description, stdout, stderr, exit_status)
        parts = []

        # Add description if provided
        parts << "Running: #{description}" if description

        # Add command
        parts << "$ #{command}"
        parts << ""

        # Add exit status
        parts << "Exit code: #{exit_status}"

        # Add stdout if present
        if stdout && !stdout.empty?
          parts << ""
          parts << "STDOUT:"
          parts << stdout.chomp
        end

        # Add stderr if present
        if stderr && !stderr.empty?
          parts << ""
          parts << "STDERR:"
          parts << stderr.chomp
        end

        # Add warning for non-zero exit
        if exit_status != 0
          parts << ""
          parts << "<system-reminder>Command exited with non-zero status (#{exit_status}). Check STDERR for error details.</system-reminder>"
        end

        parts.join("\n")
      end

      def add_usage_reminders(output, command)
        reminders = []

        # Detect file operation commands that should use dedicated tools
        if command.match?(/\b(cat|head|tail|less|more)\s+/)
          reminders << "You used a command to read a file. Consider using the Read tool instead for better formatting and error handling."
        end

        if command.match?(/\b(grep|rg|ag)\s+/)
          reminders << "You used grep/ripgrep to search files. Consider using the Grep tool instead for structured results."
        end

        if command.match?(/\b(find|locate)\s+/)
          reminders << "You used find to locate files. Consider using the Glob tool instead for pattern-based file matching."
        end

        if command.match?(/\b(sed|awk)\s+/) && !command.include?("|")
          reminders << "You used sed/awk for file editing. Consider using the Edit tool instead for safer, tracked file modifications."
        end

        if command.match?(/\becho\s+.*>\s*/) || command.match?(/\bcat\s*<</)
          reminders << "You used echo/cat with redirection to write a file. Consider using the Write tool instead for proper file creation."
        end

        return output if reminders.empty?

        output + "\n\n<system-reminder>\n#{reminders.join("\n\n")}\n</system-reminder>"
      end
    end
  end
end
