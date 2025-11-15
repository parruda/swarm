# frozen_string_literal: true

module SwarmSDK
  module Tools
    # MultiEdit tool for performing multiple exact string replacements in a file
    #
    # Applies multiple edit operations sequentially to a single file.
    # Each edit sees the result of all previous edits, allowing for
    # coordinated multi-step transformations.
    # Enforces read-before-edit rule.
    class MultiEdit < RubyLLM::Tool
      include PathResolver

      # Factory pattern: declare what parameters this tool needs for instantiation
      class << self
        def creation_requirements
          [:agent_name, :directory]
        end
      end

      description <<~DESC
        Performs multiple exact string replacements in a single file.
        Edits are applied sequentially, so later edits see the results of earlier ones.
        You must use your Read tool at least once in the conversation before editing.
        This tool will error if you attempt an edit without reading the file.
        When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix.
        The line number prefix format is: spaces + line number + tab. Everything after that tab is the actual file content to match.
        Never include any part of the line number prefix in the old_string or new_string.
        ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
        Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
        Each edit will FAIL if old_string is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use replace_all to change every instance of old_string.
        Use replace_all for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.

        IMPORTANT - Path Handling:
        - Relative paths (e.g., "tmp/file.txt", "src/main.rb") are resolved relative to your agent's working directory
        - Absolute paths (e.g., "/tmp/file.txt", "/etc/passwd") are treated as system absolute paths
        - When the user says "tmp/file.txt" they mean the tmp directory in your working directory, NOT /tmp
        - Only use absolute paths (starting with /) when explicitly referring to system-level paths
      DESC

      param :file_path,
        type: "string",
        desc: "Path to the file. Use relative paths (e.g., 'tmp/file.txt') for files in your working directory, or absolute paths (e.g., '/etc/passwd') for system files.",
        required: true

      param :edits_json,
        type: "string",
        desc: <<~DESC.chomp,
          JSON array of edit operations. Each edit must have:
          old_string (exact text to replace),
          new_string (replacement text),
          and optionally replace_all (boolean, default false).
          Example: [{"old_string":"foo","new_string":"bar","replace_all":false}]
        DESC
        required: true

      # Initialize the MultiEdit tool for a specific agent
      #
      # @param agent_name [Symbol, String] The agent identifier
      # @param directory [String] Agent's working directory
      def initialize(agent_name:, directory:)
        super()
        initialize_agent_context(agent_name: agent_name, directory: directory)
      end

      # Override name to return simple "MultiEdit" instead of full class path
      def name
        "MultiEdit"
      end

      def execute(file_path:, edits_json:)
        # Validate inputs
        return validation_error("file_path is required") if file_path.nil? || file_path.to_s.strip.empty?

        # CRITICAL: Resolve path against agent directory
        resolved_path = resolve_path(file_path)

        # Parse JSON
        edits = begin
          JSON.parse(edits_json)
        rescue JSON::ParserError
          nil
        end

        return validation_error("Invalid JSON format. Please provide a valid JSON array of edit operations.") if edits.nil?

        return validation_error("edits must be an array") unless edits.is_a?(Array)
        return validation_error("edits array cannot be empty") if edits.empty?

        # File must exist (use resolved path)
        unless File.exist?(resolved_path)
          return validation_error("File does not exist: #{file_path}")
        end

        # Enforce read-before-edit (use resolved path)
        unless Stores::ReadTracker.file_read?(@agent_name, resolved_path)
          return validation_error(
            "Cannot edit file without reading it first. " \
              "You must use the Read tool on '#{file_path}' before editing it. " \
              "This ensures you have the current file contents to match against.",
          )
        end

        # Read current content (use resolved path)
        content = File.read(resolved_path, encoding: "UTF-8")

        # Validate edit operations
        validated_edits = []
        edits.each_with_index do |edit, index|
          unless edit.is_a?(Hash)
            return validation_error("Edit at index #{index} must be a hash/object with old_string and new_string")
          end

          # Convert string keys to symbols for consistency
          edit = edit.transform_keys(&:to_sym)

          unless edit[:old_string]
            return validation_error("Edit at index #{index} missing required field 'old_string'")
          end

          unless edit[:new_string]
            return validation_error("Edit at index #{index} missing required field 'new_string'")
          end

          # old_string and new_string must be different
          if edit[:old_string] == edit[:new_string]
            return validation_error("Edit at index #{index}: old_string and new_string must be different")
          end

          validated_edits << {
            old_string: edit[:old_string].to_s,
            new_string: edit[:new_string].to_s,
            replace_all: edit[:replace_all] == true,
            index: index,
          }
        end

        # Apply edits sequentially
        results = []
        current_content = content

        validated_edits.each do |edit|
          # Check if old_string exists in current content
          unless current_content.include?(edit[:old_string])
            return error_with_results(
              <<~ERROR.chomp,
                Edit #{edit[:index]}: old_string not found in file.
                Make sure it matches exactly, including all whitespace and indentation.
                Do not include line number prefixes from Read tool output.
                Note: This edit follows #{edit[:index]} previous edit(s) which may have changed the file content.
              ERROR
              results,
            )
          end

          # Count occurrences
          occurrences = current_content.scan(edit[:old_string]).count

          # If not replace_all and multiple occurrences, error
          if !edit[:replace_all] && occurrences > 1
            return error_with_results(
              <<~ERROR.chomp,
                Edit #{edit[:index]}: Found #{occurrences} occurrences of old_string.
                Either provide more surrounding context to make the match unique, or set replace_all: true to replace all occurrences.
              ERROR
              results,
            )
          end

          # Perform replacement
          new_content = if edit[:replace_all]
            current_content.gsub(edit[:old_string], edit[:new_string])
          else
            current_content.sub(edit[:old_string], edit[:new_string])
          end

          # Record result
          replaced_count = edit[:replace_all] ? occurrences : 1
          results << {
            index: edit[:index],
            status: "success",
            occurrences: replaced_count,
            message: "Replaced #{replaced_count} occurrence(s)",
          }

          # Update content for next edit
          current_content = new_content
        end

        # Write back to file (use resolved path)
        File.write(resolved_path, current_content, encoding: "UTF-8")

        # Build success message
        total_replacements = results.sum { |r| r[:occurrences] }
        message = "Successfully applied #{validated_edits.size} edit(s) to #{file_path}\n"
        message += "Total replacements: #{total_replacements}\n\n"
        message += "Details:\n"
        results.each do |result|
          message += "  Edit #{result[:index]}: #{result[:message]}\n"
        end

        message
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        error("File contains invalid UTF-8. Cannot edit binary or improperly encoded files.")
      rescue Errno::EACCES
        error("Permission denied: Cannot read or write file '#{file_path}'")
      rescue StandardError => e
        error("Unexpected error editing file: #{e.class.name} - #{e.message}")
      end

      private

      # Format an error that includes partial results
      #
      # Shows what edits succeeded before the error occurred.
      #
      # @param message [String] Error description
      # @param results [Array<Hash>] Successful edit results before failure
      # @return [String] Formatted error message with results summary
      def error_with_results(message, results)
        output = "<tool_use_error>InputValidationError: #{message}\n\n"

        if results.any?
          output += "Previous successful edits before error:\n"
          results.each do |result|
            output += "  Edit #{result[:index]}: #{result[:message]}\n"
          end
          output += "\n"
        end

        output += "Note: The file has NOT been modified. All or nothing approach - if any edit fails, no changes are saved.</tool_use_error>"
        output
      end
    end
  end
end
