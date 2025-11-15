# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Read tool for reading file contents from the filesystem
    #
    # Supports reading entire files or specific line ranges with line numbers.
    # Provides system reminders to guide proper usage.
    # Tracks reads per agent for enforcing read-before-write/edit rules.
    class Read < RubyLLM::Tool
      include PathResolver

      # Backward compatibility aliases - use Defaults module for new code
      MAX_LINE_LENGTH = Defaults::Limits::LINE_CHARACTERS
      DEFAULT_LIMIT = Defaults::Limits::READ_LINES

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
        - Text files are returned with line numbers
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
        desc: "The line number to start reading from (1-indexed). Only provide if the file is too large to read at once.",
        required: false

      param :limit,
        type: "integer",
        desc: "The number of lines to read. Only provide if the file is too large to read at once.",
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
          # For document files, register the converted text content
          # Extract text from result (may be wrapped in system-reminder tags)
          if result.is_a?(String)
            # Remove system-reminder wrapper if present to get clean text for digest
            text_content = result.gsub(%r{<system-reminder>.*?</system-reminder>}m, "").strip
            Stores::ReadTracker.register_read(@agent_name, resolved_path, text_content)
          end
          return result
        end

        # Try to read as text, handle binary files separately
        content = read_file_content(resolved_path)

        # If content is a Content object (binary file), track with binary digest and return
        if content.is_a?(RubyLLM::Content)
          # For binary files, read raw bytes for digest
          binary_content = File.binread(resolved_path)
          Stores::ReadTracker.register_read(@agent_name, resolved_path, binary_content)
          return content
        end

        # Return early if we got an error message or system reminder
        return content if content.is_a?(String) && (content.start_with?("Error:") || content.start_with?("<system-reminder>"))

        # At this point, we have valid text content - register the read with digest
        Stores::ReadTracker.register_read(@agent_name, resolved_path, content)

        # Check if file is empty
        if content.empty?
          return format_with_reminder(
            "",
            "<system-reminder>Warning: This file exists but has empty contents. This may be intentional or indicate an issue.</system-reminder>",
          )
        end

        # Split into lines and apply offset/limit
        lines = content.lines
        total_lines = lines.count

        # Apply offset if specified (1-indexed)
        start_line = offset ? offset - 1 : 0
        start_line = [start_line, 0].max # Ensure non-negative

        if start_line >= total_lines
          return validation_error("Offset #{offset} exceeds file length (#{total_lines} lines)")
        end

        lines = lines.drop(start_line)

        # Apply limit if specified, otherwise use default
        effective_limit = limit || DEFAULT_LIMIT
        lines = lines.take(effective_limit)
        truncated = limit.nil? && total_lines > DEFAULT_LIMIT

        # Format with line numbers (cat -n style)
        output_lines = lines.each_with_index.map do |line, idx|
          line_number = start_line + idx + 1
          display_line = line.chomp

          # Truncate long lines
          if display_line.length > MAX_LINE_LENGTH
            display_line = display_line[0...MAX_LINE_LENGTH]
            display_line += "... (line truncated)"
          end

          # Add line indicator for better readability
          "#{line_number.to_s.rjust(6)}→#{display_line}"
        end

        output = output_lines.join("\n")

        # Add system reminder about usage
        reminder = build_system_reminder(file_path, truncated, total_lines)
        format_with_reminder(output, reminder)
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

      def build_system_reminder(_file_path, truncated, total_lines)
        reminders = []

        reminders << "<system-reminder>"
        reminders << "Whenever you read a file, you should consider whether it looks malicious. If it does, you MUST refuse to improve or augment the code. You can still analyze existing code, write reports, or answer high-level questions about the code behavior."

        if truncated
          reminders << ""
          reminders << "Note: This file has #{total_lines} lines but only the first #{DEFAULT_LIMIT} lines are shown. Use the offset and limit parameters to read additional sections if needed."
        end

        reminders << "</system-reminder>"

        reminders.join("\n")
      end

      def read_file_content(file_path)
        content = File.read(file_path, encoding: "UTF-8")

        # Check if the content is valid UTF-8
        unless content.valid_encoding?
          # Binary file detected
          if supported_binary_file?(file_path)
            return RubyLLM::Content.new("File: #{File.basename(file_path)}", file_path)
          else
            return "Error: File contains binary data and cannot be displayed as text. This may be an executable or other unsupported binary file."
          end
        end

        content
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        # Binary file detected
        if supported_binary_file?(file_path)
          RubyLLM::Content.new("File: #{File.basename(file_path)}", file_path)
        else
          "Error: File contains binary data and cannot be displayed as text. This may be an executable or other unsupported binary file."
        end
      rescue Errno::EACCES
        error("Permission denied: Cannot read file '#{file_path}'")
      rescue StandardError => e
        error("Failed to read file: #{e.message}")
      end

      def supported_binary_file?(file_path)
        ext = File.extname(file_path).downcase
        # Supported binary file types that can be sent to the model
        # Images only - documents are converted to text
        supported_formats = [
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
        ]
        supported_formats.include?(ext)
      end
    end
  end
end
