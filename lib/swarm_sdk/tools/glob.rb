# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Glob tool for fast file and directory pattern matching
    #
    # Finds files and directories matching glob patterns, sorted by modification time.
    # Works efficiently with any codebase size.
    class Glob < RubyLLM::Tool
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

      define_method(:name) { "Glob" }

      description <<~DESC
        - Fast file pattern matching tool that works with any directory size

        - Supports glob patterns like "**/*.js" or "src/**/*.ts"

        - Returns matching file paths sorted by modification time

        - Use this tool when you need to find files by name patterns

        - When you are doing an open ended search that may require multiple rounds of
        globbing and grepping, use the Agent tool instead

        - You have the capability to call multiple tools in a single response. It is
        always better to speculatively perform multiple searches as a batch that are
        potentially useful.
      DESC

      param :pattern,
        type: "string",
        desc: "The glob pattern to match files against",
        required: true

      param :path,
        type: "string",
        desc: "The directory to search in. If not specified, the current working directory will be used. IMPORTANT: Omit this field to use the default directory. DO NOT enter \"undefined\" or \"null\" - simply omit it for the default behavior. Must be a valid directory path if provided.",
        required: false

      # Backward compatibility alias - use Defaults module for new code
      MAX_RESULTS = Defaults::Limits::GLOB_RESULTS

      def execute(pattern:, path: nil)
        # Validate inputs
        return validation_error("pattern is required") if pattern.nil? || pattern.to_s.strip.empty?

        # Validate path if provided
        if path && !path.to_s.strip.empty?
          # Check for literal "undefined" or "null" strings
          if path.to_s.strip.downcase == "undefined" || path.to_s.strip.downcase == "null"
            return validation_error("Invalid path value. Omit the path parameter entirely to use the current working directory.")
          end

          unless File.exist?(path)
            return validation_error("Path does not exist: #{path}")
          end

          unless File.directory?(path)
            return validation_error("Path is not a directory: #{path}")
          end

          # CRITICAL: Resolve relative paths against agent directory
          search_path = resolve_path(path)
        else
          # CRITICAL: Use agent's directory as default (NOT Dir.pwd)
          search_path = @directory
        end

        # Execute glob from specified path
        begin
          # Build full pattern by joining search path with pattern
          # If pattern is already absolute, File.join will use it as-is
          full_pattern = if pattern.start_with?("/")
            # Pattern is absolute, use it directly
            pattern
          else
            # Pattern is relative, join with search path
            File.join(search_path, pattern)
          end

          matches = Dir.glob(full_pattern, File::FNM_DOTMATCH)

          # Remove . and .. entries (handle both with and without trailing slashes)
          matches.reject! do |f|
            basename = File.basename(f.chomp("/"))
            basename == "." || basename == ".."
          end

          # Handle no matches
          if matches.empty?
            return "No matches found for pattern: #{pattern}"
          end

          # Sort by modification time (most recent first)
          matches.sort_by! { |f| -File.mtime(f).to_i }

          # Limit results
          if matches.count > MAX_RESULTS
            matches = matches.take(MAX_RESULTS)
            truncated = true
          else
            truncated = false
          end

          # Format output
          output = matches.join("\n")

          # Add system reminder if truncated
          if truncated
            output += <<~REMINDER

              <system-reminder>
              Results limited to first #{MAX_RESULTS} matches (sorted by most recently modified).
              Consider using a more specific pattern to narrow your search.
              </system-reminder>
            REMINDER
          end

          # Add usage reminder
          output += "\n\n" + build_usage_reminder(matches.count, pattern)

          output
        rescue Errno::EACCES => e
          error("Permission denied: #{e.message}")
        rescue StandardError => e
          error("Failed to execute glob: #{e.class.name} - #{e.message}")
        end
      rescue StandardError => e
        error("Unexpected error during glob: #{e.class.name} - #{e.message}")
      end

      private

      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end

      def error(message)
        "Error: #{message}"
      end

      def build_usage_reminder(count, pattern)
        <<~REMINDER
          <system-reminder>
          Found #{count} match#{"es" if count != 1} for '#{pattern}' (files and directories).
          These paths are sorted by modification time (most recent first).
          You can now use the Read tool to examine specific files, or use Grep to search within these files.
          </system-reminder>
        REMINDER
      end
    end
  end
end
