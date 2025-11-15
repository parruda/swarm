# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Grep tool for searching file contents using ripgrep-style patterns
    #
    # Powerful search capabilities with regex support, context lines, and filtering.
    # Built on ripgrep (rg) for fast, efficient searching.
    class Grep < RubyLLM::Tool
      include PathResolver

      # Factory pattern: declare what parameters this tool needs for instantiation
      class << self
        def creation_requirements
          [:directory]
        end
      end

      def initialize(directory:)
        super()
        @directory = File.expand_path(directory)
      end

      define_method(:name) { "Grep" }

      description <<~DESC
        A powerful search tool built on ripgrep

        Usage:
        - ALWAYS use Grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The Grep tool has been optimized for correct permissions and access.
        - Supports full regex syntax (e.g., "log.*Error", "function\\s+\\w+")
        - Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")
        - Output modes: "content" shows matching lines, "files_with_matches" shows only file paths (default), "count" shows match counts
        - Use Task tool for open-ended searches requiring multiple rounds
        - Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\\{\\}` to find `interface{}` in Go code)
        - Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \\{[\\s\\S]*?field`, use `multiline: true`
      DESC

      param :pattern,
        type: "string",
        desc: "The regular expression pattern to search for in file contents",
        required: true

      param :path,
        type: "string",
        desc: "File or directory to search in (rg PATH). Defaults to current working directory.",
        required: false

      param :glob,
        type: "string",
        desc: "Glob pattern to filter files (e.g. \"*.js\", \"*.{ts,tsx}\") - maps to rg --glob",
        required: false

      param :type,
        type: "string",
        desc: "File type to search (rg --type). Common types: c, cpp, cs, csharp, css, dart, docker, dockercompose, elixir, erlang, go, graphql, haskell, html, java, js, json, kotlin, lua, make, markdown, md, php, py, python, ruby, rust, sass, scala, sh, sql, svelte, swift, tf, toml, ts, typescript, vim, vue, xml, yaml, zig",
        required: false

      param :output_mode,
        type: "string",
        desc: "Output mode: \"content\" shows matching lines (supports context/line number options), \"files_with_matches\" shows file paths (default), \"count\" shows match counts. All modes support head_limit.",
        required: false

      param :case_insensitive,
        type: "boolean",
        desc: "Case insensitive search (rg -i)",
        required: false

      param :multiline,
        type: "boolean",
        desc: "Enable multiline mode where . matches newlines and patterns can span lines (rg -U --multiline-dotall)",
        required: false

      param :context_before,
        type: "integer",
        desc: "Number of lines to show before each match (rg -B). Requires output_mode: \"content\", ignored otherwise.",
        required: false

      param :context_after,
        type: "integer",
        desc: "Number of lines to show after each match (rg -A). Requires output_mode: \"content\", ignored otherwise.",
        required: false

      param :context,
        type: "integer",
        desc: "Number of lines to show before and after each match (rg -C). Requires output_mode: \"content\", ignored otherwise.",
        required: false

      param :show_line_numbers,
        type: "boolean",
        desc: "Show line numbers in output (rg -n). Requires output_mode: \"content\", ignored otherwise.",
        required: false

      param :head_limit,
        type: "integer",
        desc: "Limit output to first N lines/entries, equivalent to \"| head -N\". Works across all output modes: content (limits output lines), files_with_matches (limits file paths), count (limits count entries). When unspecified, shows all results from ripgrep.",
        required: false

      def execute(
        pattern:,
        path: nil,
        glob: nil,
        type: nil,
        output_mode: "files_with_matches",
        case_insensitive: false,
        multiline: false,
        context_before: nil,
        context_after: nil,
        context: nil,
        show_line_numbers: false,
        head_limit: nil
      )
        # Validate inputs
        return validation_error("pattern is required") if pattern.nil? || pattern.empty?

        # CRITICAL: Default path to agent's directory (NOT current directory)
        path = if path.nil? || path.to_s.strip.empty?
          @directory
        else
          # Resolve relative paths against agent directory
          resolve_path(path)
        end

        # Validate output_mode
        valid_modes = ["content", "files_with_matches", "count"]
        unless valid_modes.include?(output_mode)
          return validation_error("output_mode must be one of: #{valid_modes.join(", ")}")
        end

        # Build ripgrep command
        cmd = ["rg"]

        # Output mode flags
        case output_mode
        when "files_with_matches"
          cmd << "-l" # List files with matches
        when "count"
          cmd << "-c" # Count matches per file
        when "content"
          # Default mode, no special flag needed
          # Add line numbers if requested
          cmd << "-n" if show_line_numbers

          # Add context flags
          cmd << "-B" << context_before.to_s if context_before
          cmd << "-A" << context_after.to_s if context_after
          cmd << "-C" << context.to_s if context
        end

        # Case sensitivity
        cmd << "-i" if case_insensitive

        # Multiline mode
        if multiline
          cmd << "-U" << "--multiline-dotall"
        end

        # File filtering (only add if non-empty)
        cmd << "--type" << type if type && !type.to_s.strip.empty?
        cmd << "--glob" << glob if glob && !glob.to_s.strip.empty?

        # Pattern
        cmd << "-e" << pattern

        # Path
        cmd << path

        # Execute command
        begin
          require "open3"

          stdout, stderr, status = Open3.capture3(*cmd)

          # Handle no matches (exit code 1 for ripgrep means no matches found)
          if status.exitstatus == 1 && stderr.empty?
            return "No matches found for pattern: #{pattern}"
          end

          # Handle errors (exit code 2 means error)
          if status.exitstatus == 2 || !stderr.empty?
            return error("ripgrep error: #{stderr}")
          end

          # Success - format output
          output = stdout

          # Apply head_limit if specified
          if head_limit && head_limit > 0
            lines = output.lines
            if lines.count > head_limit
              output = lines.take(head_limit).join
              output += "\n\n<system-reminder>Output limited to first #{head_limit} lines. Total results: #{lines.count} lines.</system-reminder>"
            end
          end

          # Add reminder about usage
          reminder = build_usage_reminder(output_mode, pattern)
          output = "#{output}\n\n#{reminder}" unless reminder.empty?

          output.empty? ? "No matches found for pattern: #{pattern}" : output
        rescue Errno::ENOENT
          error("ripgrep (rg) is not installed or not in PATH. Please install ripgrep to use the Grep tool.")
        rescue Errno::EACCES
          error("Permission denied: Cannot search in '#{path}'")
        rescue StandardError => e
          error("Failed to execute search: #{e.class.name} - #{e.message}")
        end
      rescue StandardError => e
        error("Unexpected error during search: #{e.class.name} - #{e.message}")
      end

      private

      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end

      def error(message)
        "Error: #{message}"
      end

      def build_usage_reminder(output_mode, pattern)
        return "" if output_mode == "content"

        <<~REMINDER
          <system-reminder>
          You used output_mode: '#{output_mode}' which only shows #{output_mode == "files_with_matches" ? "file paths" : "match counts"}.
          To see the actual matching lines and their content, use output_mode: 'content'.
          You can also add show_line_numbers: true and context lines (context_before, context_after, or context) for better context.
          </system-reminder>
        REMINDER
      end
    end
  end
end
