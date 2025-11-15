# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Edit tool for performing exact string replacements in files
    #
    # Uses exact string matching to find and replace content.
    # Requires unique matches and proper Read tool usage beforehand.
    # Enforces read-before-edit rule.
    class Edit < RubyLLM::Tool
      include PathResolver

      # Factory pattern: declare what parameters this tool needs for instantiation
      class << self
        def creation_requirements
          [:agent_name, :directory]
        end
      end

      description <<~DESC
        Performs exact string replacements in files.
        You must use your Read tool at least once in the conversation before editing.
        This tool will error if you attempt an edit without reading the file.
        When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix.
        The line number prefix format is: spaces + line number + tab. Everything after that tab is the actual file content to match.
        Never include any part of the line number prefix in the old_string or new_string.
        ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
        Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
        The edit will FAIL if old_string is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use replace_all to change every instance of old_string.
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

      param :old_string,
        type: "string",
        desc: "The exact text to replace (must match exactly including whitespace)",
        required: true

      param :new_string,
        type: "string",
        desc: "The text to replace it with (must be different from old_string)",
        required: true

      param :replace_all,
        type: "boolean",
        desc: "Replace all occurrences of old_string (default false)",
        required: false

      # Initialize the Edit tool for a specific agent
      #
      # @param agent_name [Symbol, String] The agent identifier
      # @param directory [String] Agent's working directory
      def initialize(agent_name:, directory:)
        super()
        initialize_agent_context(agent_name: agent_name, directory: directory)
      end

      # Override name to return simple "Edit" instead of full class path
      def name
        "Edit"
      end

      def execute(file_path:, old_string:, new_string:, replace_all: false)
        # Validate inputs
        return validation_error("file_path is required") if file_path.nil? || file_path.to_s.strip.empty?
        return validation_error("old_string is required") if old_string.nil? || old_string.empty?
        return validation_error("new_string is required") if new_string.nil?

        # old_string and new_string must be different
        if old_string == new_string
          return validation_error("old_string and new_string must be different. They are currently identical.")
        end

        # CRITICAL: Resolve path against agent directory
        resolved_path = resolve_path(file_path)

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

        # Check if old_string exists in file
        unless content.include?(old_string)
          return validation_error(<<~ERROR.chomp)
            old_string not found in file. Make sure it matches exactly, including all whitespace and indentation.
            Do not include line number prefixes from Read tool output.
          ERROR
        end

        # Count occurrences
        occurrences = content.scan(old_string).count

        # If not replace_all and multiple occurrences, error
        if !replace_all && occurrences > 1
          return validation_error(<<~ERROR.chomp)
            Found #{occurrences} occurrences of old_string.
            Either provide more surrounding context to make the match unique, or use replace_all: true to replace all occurrences.
          ERROR
        end

        # Perform replacement
        new_content = if replace_all
          content.gsub(old_string, new_string)
        else
          content.sub(old_string, new_string)
        end

        # Write back to file (use resolved path)
        File.write(resolved_path, new_content, encoding: "UTF-8")

        # Build success message
        replaced_count = replace_all ? occurrences : 1
        "Successfully replaced #{replaced_count} occurrence(s) in #{file_path}"
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        error("File contains invalid UTF-8. Cannot edit binary or improperly encoded files.")
      rescue Errno::EACCES
        error("Permission denied: Cannot read or write file '#{file_path}'")
      rescue StandardError => e
        error("Unexpected error editing file: #{e.class.name} - #{e.message}")
      end
    end
  end
end
