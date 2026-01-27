# frozen_string_literal: true

module SwarmMemory
  module Tools
    # Tool for editing memory entries with exact string replacement
    #
    # Performs exact string replacements in memory content.
    # Each agent has its own isolated memory storage.
    class MemoryEdit < SwarmSDK::Tools::Base
      removable false # Memory tools are always available
      description <<~DESC
        Perform exact string replacements in memory entries (works like Edit tool but for memory content).

        REQUIRED: Provide ALL THREE parameters - file_path, old_string, and new_string.

        **Required Parameters:**
        - file_path (REQUIRED): Path to memory entry - MUST start with concept/, fact/, skill/, or experience/
        - old_string (REQUIRED): The exact text to replace - must match exactly including all whitespace and indentation
        - new_string (REQUIRED): The replacement text - must be different from old_string

        **MEMORY STRUCTURE (4 Fixed Categories Only):**
        - concept/{domain}/{name}.md - Abstract ideas
        - fact/{subfolder}/{name}.md - Concrete information
        - skill/{domain}/{name}.md - Procedures
        - experience/{name}.md - Lessons
        INVALID: documentation/, reference/, analysis/, parallel/, tutorial/

        **Optional Parameters:**
        - replace_all: Set to true to replace all occurrences (default: false, replaces only first occurrence)

        **CRITICAL - Before Using This Tool:**
        1. You MUST use MemoryRead on the entry first - edits without reading will FAIL
        2. Copy text exactly from MemoryRead output
        3. Preserve exact indentation and whitespace from the original content

        **How It Works:**
        - If old_string appears once: replacement succeeds
        - If old_string appears multiple times: FAILS unless replace_all=true
        - If old_string not found: FAILS with helpful error
        - Make old_string unique by including more surrounding context

        **Examples:**
        ```
        # Update a fact
        MemoryEdit(
          file_path: "fact/people/john.md",
          old_string: "status: active",
          new_string: "status: inactive"
        )

        # Update a skill
        MemoryEdit(
          file_path: "skill/debugging/api-errors.md",
          old_string: "TODO: Add error codes",
          new_string: "Common error codes: 401, 403, 404, 500",
          replace_all: true
        )

        # Update a concept
        MemoryEdit(
          file_path: "concept/ruby/classes.md",
          old_string: "def calculate_total(items)\n  return sum(items)\nend",
          new_string: "def compute_sum(items)\n  items.sum\nend"
        )
        ```

        **Common Mistakes to Avoid:**
        - Not reading the entry first with MemoryRead
        - Not matching whitespace exactly
        - Trying to replace non-unique text without replace_all
      DESC

      param :file_path,
        desc: "Path to memory entry - MUST start with concept/, fact/, skill/, or experience/ (e.g., 'concept/ruby/classes.md', 'skill/debugging/api.md')",
        required: true

      param :old_string,
        desc: "The exact text to replace (must match exactly including whitespace)",
        required: true

      param :new_string,
        desc: "The text to replace it with (must be different from old_string)",
        required: true

      param :replace_all,
        desc: "Replace all occurrences of old_string (default false)",
        type: :boolean,
        required: false

      # Initialize with storage instance and agent name
      #
      # @param storage [Core::Storage] Storage instance
      # @param agent_name [String, Symbol] Agent identifier
      def initialize(storage:, agent_name:)
        super()
        @storage = storage
        @agent_name = agent_name.to_sym
      end

      # Override name to return simple "MemoryEdit"
      def name
        "MemoryEdit"
      end

      # Execute the tool
      #
      # @param file_path [String] Path to memory entry
      # @param old_string [String] Text to replace
      # @param new_string [String] Replacement text
      # @param replace_all [Boolean] Replace all occurrences
      # @return [String] Success message or error
      def execute(file_path:, old_string:, new_string:, replace_all: false)
        # Validate inputs
        return validation_error("file_path is required") if file_path.nil? || file_path.to_s.strip.empty?
        return validation_error("old_string is required") if old_string.nil? || old_string.empty?
        return validation_error("new_string is required") if new_string.nil?

        # old_string and new_string must be different
        if old_string == new_string
          return validation_error("old_string and new_string must be different. They are currently identical.")
        end

        # Read current content (this will raise ArgumentError if entry doesn't exist)
        content = @storage.read(file_path: file_path)

        # Enforce read-before-edit with content verification
        unless Core::StorageReadTracker.entry_read?(@agent_name, file_path, @storage)
          return validation_error(
            "Cannot edit memory entry without reading it first. " \
              "You must use MemoryRead on 'memory://#{file_path}' before editing it. " \
              "This ensures you have the current content to match against.",
          )
        end

        # Check if old_string exists in content
        unless content.include?(old_string)
          return validation_error(
            "old_string not found in memory entry. Make sure it matches exactly, including all whitespace and indentation.",
          )
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

        # Get existing entry metadata
        entry = @storage.read_entry(file_path: file_path)

        # Write updated content back (preserving the title and metadata)
        @storage.write(
          file_path: file_path,
          content: new_content,
          title: entry.title,
          metadata: entry.metadata,
        )

        # Build success message
        replaced_count = replace_all ? occurrences : 1
        "Successfully replaced #{replaced_count} occurrence(s) in memory://#{file_path}"
      rescue ArgumentError => e
        validation_error(e.message)
      end

      private

      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end
    end
  end
end
