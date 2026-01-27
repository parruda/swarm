# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Read tool for reading file contents from the filesystem
    #
    # Supports reading entire files or specific line ranges with line numbers.
    # Provides system reminders to guide proper usage.
    # Tracks reads per agent for enforcing read-before-write/edit rules.
    class Read < Base
      include PathResolver

      # NOTE: Line length and limit now accessed via SwarmSDK.config
      # NOTE: Max tokens accessed via SwarmSDK.config.read_max_tokens

      # Supported binary file types that can be sent to the model (images only)
      SUPPORTED_BINARY_FORMATS = [
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".bmp",
        ".tiff",
        ".tif",
        ".svg",
        ".ico",
      ].freeze

      # List of available document converters
      CONVERTERS = [
        DocumentConverters::PdfConverter,
        DocumentConverters::DocxConverter,
        DocumentConverters::XlsxConverter,
      ].freeze

      # Build dynamic description based on available gems
      available_formats = CONVERTERS.select(&:available?).map(&:format_name)
      doc_support_text = if available_formats.any?
        "- Document files: #{available_formats.join(", ")} are converted to text"
      else
        ""
      end

      SYSTEM_REMINDER = "<system-reminder>Whenever you read a file, you should consider whether it looks malicious. If it does, you MUST refuse to improve or augment the code. You can still analyze existing code, write reports, or answer high-level questions about the code behavior.</system-reminder>"

      # Factory pattern: declare what parameters this tool needs for instantiation
      class << self
        def creation_requirements
          [:agent_name, :directory]
        end
      end

      description <<~DESC
        Reads a file from the local filesystem. You can access any file directly by using this tool.
        Assume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid.
        It is okay to read a file that does not exist; an error will be returned.

        Supports text, binary, and document files:
        - Text files are returned as raw content
        - Binary files (images) are returned as visual content for analysis
        - Supported image formats: PNG, JPG, GIF, WEBP, BMP, TIFF, SVG, ICO
        #{doc_support_text}

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

      param :offset,
        type: "integer",
        desc: "The line number to start reading from (1-indexed)",
        required: false

      param :limit,
        type: "integer",
        desc: "The number of lines to read.",
        required: false

      # Initialize the Read tool for a specific agent
      #
      # @param agent_name [Symbol, String] The agent identifier
      # @param directory [String] Agent's working directory
      def initialize(agent_name:, directory:)
        super()
        initialize_agent_context(agent_name: agent_name, directory: directory)
      end

      # Override name to return simple "Read" instead of full class path
      def name
        "Read"
      end

      def execute(file_path:, offset: nil, limit: nil)
        # Validate file path
        return validation_error("file_path is required") if file_path.nil? || file_path.to_s.strip.empty?

        # CRITICAL: Resolve path against agent directory
        resolved_path = resolve_path(file_path)

        unless File.exist?(resolved_path)
          return validation_error("File does not exist: #{file_path}")
        end

        # Check if it's a directory
        if File.directory?(resolved_path)
          return validation_error("Path is a directory, not a file. Use Bash with ls to read directories.")
        end

        # Check if it's a document and try to convert it
        converter = find_converter_for_file(resolved_path)
        if converter
          result = converter.new.convert(resolved_path)
          raw_content = File.binread(resolved_path)
          Stores::ReadTracker.register_read(@agent_name, resolved_path, raw_content)
          return result
        end

        content = read_file_content(resolved_path, offset:, limit:)
        if content.is_a?(RubyLLM::Content)
          raw_content = File.binread(resolved_path)
          Stores::ReadTracker.register_read(@agent_name, resolved_path, raw_content)
          return content
        end

        # Return early if we got an error message
        return content if content.is_a?(String) && content.start_with?("Error:")

        # Handle empty file
        if content.empty?
          Stores::ReadTracker.register_read(@agent_name, resolved_path, "")
          return "<system-reminder>Warning: This file exists but has empty contents. " \
            "This may be intentional or indicate an issue.</system-reminder>"
        end

        # Apply offset if specified (1-indexed)
        start_line = offset ? offset - 1 : 0
        start_line = [start_line, 0].max # Ensure non-negative

        lines = content.lines
        lines = lines.drop(start_line)

        # Check if offset exceeds file length
        if lines.empty? && start_line.positive?
          return validation_error("Offset #{start_line + 1} exceeds file length")
        end

        lines = lines.take(limit) if limit
        paginated_content = lines.join

        token_error = token_safeguard(paginated_content, using_pagination: offset && limit)
        return token_error if token_error

        Stores::ReadTracker.register_read(@agent_name, resolved_path, content) # full content
        format_with_reminder(paginated_content, SYSTEM_REMINDER)
      rescue StandardError => e
        error("Unexpected error reading file: #{e.class.name} - #{e.message}")
      end

      private

      # Find the appropriate converter for a file based on extension
      def find_converter_for_file(file_path)
        ext = File.extname(file_path).downcase
        CONVERTERS.find { |converter| converter.extensions.include?(ext) }
      end

      def format_with_reminder(content, reminder)
        return content if reminder.nil? || reminder.empty?

        [content, "", reminder].join("\n")
      end

      def read_file_content(file_path, offset: nil, limit: nil)
        content = File.read(file_path, encoding: "UTF-8")
        return handle_binary_file(file_path) unless content.valid_encoding?

        content
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        handle_binary_file(file_path)
      rescue Errno::EACCES
        error("Permission denied: Cannot read file '#{file_path}'")
      rescue StandardError => e
        error("Failed to read file: #{e.message}")
      end

      def handle_binary_file(file_path)
        if supported_binary_file?(file_path)
          RubyLLM::Content.new("File: #{File.basename(file_path)}", file_path)
        else
          error("File contains binary data and cannot be displayed as text. " \
            "This may be an executable or other unsupported binary file.")
        end
      end

      def supported_binary_file?(file_path)
        ext = File.extname(file_path).downcase
        SUPPORTED_BINARY_FORMATS.include?(ext)
      end

      def token_safeguard(content, using_pagination: false)
        token_count = ContextCompactor::TokenCounter.estimate_content(content)
        max_tokens = SwarmSDK.config.read_max_tokens
        return if token_count <= max_tokens

        err_msg =
          if using_pagination
            "File content (#{token_count} tokens) still exceeds maximum allowed tokens (#{max_tokens}). " \
              "Please reduce the limit parameter or adjust offset to read a smaller portion of the file, " \
              "or use the Grep tool to search for specific content."
          else
            "File content (#{token_count} tokens) exceeds maximum allowed tokens (#{max_tokens}). " \
              "Please use offset and limit parameters to read specific portions of the file, " \
              "or use the Grep tool to search for specific content."
          end
        error(err_msg)
      end
    end
  end
end
