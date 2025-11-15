# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Write tool for writing content to files
    #
    # Creates new files or overwrites existing files.
    # Enforces read-before-write rule for existing files.
    # Includes validation and usage guidelines via system reminders.
    class Write < RubyLLM::Tool
      include PathResolver

      # Factory pattern: declare what parameters this tool needs for instantiation
      class << self
        def creation_requirements
          [:agent_name, :directory]
        end
      end

      description <<~DESC
        Writes a file to the local filesystem.
        This tool will overwrite the existing file if there is one at the provided path.
        If this is an existing file, you MUST use the Read tool first to read the file's contents.
        This tool will fail if you did not read the file first.
        ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
        NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
        Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.

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

      param :content,
        type: "string",
        desc: "The content to write to the file",
        required: true

      # Initialize the Write tool for a specific agent
      #
      # @param agent_name [Symbol, String] The agent identifier
      # @param directory [String] Agent's working directory
      def initialize(agent_name:, directory:)
        super()
        initialize_agent_context(agent_name: agent_name, directory: directory)
      end

      # Override name to return simple "Write" instead of full class path
      def name
        "Write"
      end

      def execute(file_path:, content:)
        # Validate inputs
        return validation_error("file_path is required") if file_path.nil? || file_path.to_s.strip.empty?
        return validation_error("content is required") if content.nil?

        # CRITICAL: Resolve path against agent directory
        resolved_path = resolve_path(file_path)

        # Check if file already exists (use resolved path)
        file_exists = File.exist?(resolved_path)

        # Enforce read-before-write for existing files (use resolved path)
        if file_exists && !Stores::ReadTracker.file_read?(@agent_name, resolved_path)
          return validation_error(
            "Cannot write to existing file without reading it first. " \
              "You must use the Read tool on '#{file_path}' before overwriting it. " \
              "This ensures you have context about the file's current contents.",
          )
        end

        # Create parent directory if it doesn't exist (use resolved path)
        parent_dir = File.dirname(resolved_path)
        FileUtils.mkdir_p(parent_dir) unless File.directory?(parent_dir)

        # Write the file (use resolved path)
        File.write(resolved_path, content, encoding: "UTF-8")

        # Build success message
        byte_size = content.bytesize
        line_count = content.lines.count
        action = file_exists ? "overwrote" : "created"

        message = "Successfully #{action} file: #{file_path} (#{line_count} lines, #{byte_size} bytes)"

        # Add system reminder for overwritten files
        if file_exists
          reminder = "<system-reminder>You overwrote an existing file. Make sure this was intentional and that you read the file first if you needed to preserve any content.</system-reminder>"
          "#{message}\n\n#{reminder}"
        else
          message
        end
      rescue Errno::EACCES
        error("Permission denied: Cannot write to file '#{file_path}'")
      rescue Errno::EISDIR
        error("Path is a directory, not a file.")
      rescue Errno::ENOENT => e
        error("Failed to create parent directory: #{e.message}")
      rescue StandardError => e
        error("Unexpected error writing file: #{e.class.name} - #{e.message}")
      end
    end
  end
end
