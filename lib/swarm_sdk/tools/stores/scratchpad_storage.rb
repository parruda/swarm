# frozen_string_literal: true

module SwarmSDK
  module Tools
    module Stores
      # ScratchpadStorage provides volatile, shared storage
      #
      # Features:
      # - Shared: All agents share the same scratchpad
      # - Volatile: NEVER persists - all data lost when process ends
      # - Path-based: Hierarchical organization using file-path-like addresses
      # - Metadata-rich: Stores content + title + timestamp + size
      # - Thread-safe: Mutex-protected operations
      #
      # Use for temporary, cross-agent communication within a single session.
      class ScratchpadStorage < Storage
        # Initialize scratchpad storage (always volatile)
        def initialize
          super() # Initialize parent Storage class
          @entries = {}
          @total_size = 0
          @mutex = Mutex.new
        end

        # Write content to scratchpad
        #
        # @param file_path [String] Path to store content
        # @param content [String] Content to store
        # @param title [String] Brief title describing the content
        # @raise [ArgumentError] If size limits are exceeded
        # @return [Entry] The created entry
        def write(file_path:, content:, title:)
          @mutex.synchronize do
            raise ArgumentError, "file_path is required" if file_path.nil? || file_path.to_s.strip.empty?
            raise ArgumentError, "content is required" if content.nil?
            raise ArgumentError, "title is required" if title.nil? || title.to_s.strip.empty?

            content_size = content.bytesize

            # Check entry size limit
            if content_size > Defaults::Storage::ENTRY_SIZE_BYTES
              raise ArgumentError, "Content exceeds maximum size (#{format_bytes(Defaults::Storage::ENTRY_SIZE_BYTES)}). " \
                "Current: #{format_bytes(content_size)}"
            end

            # Calculate new total size
            existing_entry = @entries[file_path]
            existing_size = existing_entry ? existing_entry.size : 0
            new_total_size = @total_size - existing_size + content_size

            # Check total size limit
            if new_total_size > Defaults::Storage::TOTAL_SIZE_BYTES
              raise ArgumentError, "Scratchpad full (#{format_bytes(Defaults::Storage::TOTAL_SIZE_BYTES)} limit). " \
                "Current: #{format_bytes(@total_size)}, " \
                "Would be: #{format_bytes(new_total_size)}. " \
                "Clear old entries or use smaller content."
            end

            # Create entry
            entry = Entry.new(
              content: content,
              title: title,
              updated_at: Time.now,
              size: content_size,
            )

            # Update storage
            @entries[file_path] = entry
            @total_size = new_total_size

            entry
          end
        end

        # Read content from scratchpad
        #
        # @param file_path [String] Path to read from
        # @raise [ArgumentError] If path not found
        # @return [String] Content at the path
        def read(file_path:)
          raise ArgumentError, "file_path is required" if file_path.nil? || file_path.to_s.strip.empty?

          entry = @entries[file_path]
          raise ArgumentError, "scratchpad://#{file_path} not found" unless entry

          entry.content
        end

        # Delete a specific entry
        #
        # @param file_path [String] Path to delete
        # @raise [ArgumentError] If path not found
        # @return [void]
        def delete(file_path:)
          @mutex.synchronize do
            raise ArgumentError, "file_path is required" if file_path.nil? || file_path.to_s.strip.empty?

            entry = @entries[file_path]
            raise ArgumentError, "scratchpad://#{file_path} not found" unless entry

            # Update total size
            @total_size -= entry.size

            # Remove entry
            @entries.delete(file_path)
          end
        end

        # List scratchpad entries, optionally filtered by prefix
        #
        # @param prefix [String, nil] Filter by path prefix
        # @return [Array<Hash>] Array of entry metadata (path, title, size, updated_at)
        def list(prefix: nil)
          entries = @entries

          # Filter by prefix if provided
          if prefix && !prefix.empty?
            entries = entries.select { |path, _| path.start_with?(prefix) }
          end

          # Return metadata sorted by path
          entries.map do |path, entry|
            {
              path: path,
              title: entry.title,
              size: entry.size,
              updated_at: entry.updated_at,
            }
          end.sort_by { |e| e[:path] }
        end

        # Search entries by glob pattern
        #
        # @param pattern [String] Glob pattern (e.g., "**/*.txt", "parallel/*/task_*")
        # @return [Array<Hash>] Array of matching entry metadata, sorted by most recent first
        def glob(pattern:)
          raise ArgumentError, "pattern is required" if pattern.nil? || pattern.to_s.strip.empty?

          # Convert glob pattern to regex
          regex = glob_to_regex(pattern)

          # Filter entries by pattern
          matching_entries = @entries.select { |path, _| regex.match?(path) }

          # Return metadata sorted by most recent first
          matching_entries.map do |path, entry|
            {
              path: path,
              title: entry.title,
              size: entry.size,
              updated_at: entry.updated_at,
            }
          end.sort_by { |e| -e[:updated_at].to_f }
        end

        # Search entry content by pattern
        #
        # @param pattern [String] Regular expression pattern to search for
        # @param case_insensitive [Boolean] Whether to perform case-insensitive search
        # @param output_mode [String] Output mode: "files_with_matches" (default), "content", or "count"
        # @return [Array<Hash>, String] Results based on output_mode
        def grep(pattern:, case_insensitive: false, output_mode: "files_with_matches")
          raise ArgumentError, "pattern is required" if pattern.nil? || pattern.to_s.strip.empty?

          # Create regex from pattern
          flags = case_insensitive ? Regexp::IGNORECASE : 0
          regex = Regexp.new(pattern, flags)

          case output_mode
          when "files_with_matches"
            # Return just the paths that match
            matching_paths = @entries.select { |_path, entry| regex.match?(entry.content) }
              .map { |path, _| path }
              .sort
            matching_paths
          when "content"
            # Return paths with matching lines, sorted by most recent first
            results = []
            @entries.each do |path, entry|
              matching_lines = []
              entry.content.each_line.with_index(1) do |line, line_num|
                matching_lines << { line_number: line_num, content: line.chomp } if regex.match?(line)
              end
              results << { path: path, matches: matching_lines, updated_at: entry.updated_at } unless matching_lines.empty?
            end
            results.sort_by { |r| -r[:updated_at].to_f }.map { |r| r.except(:updated_at) }
          when "count"
            # Return paths with match counts, sorted by most recent first
            results = []
            @entries.each do |path, entry|
              count = entry.content.scan(regex).size
              results << { path: path, count: count, updated_at: entry.updated_at } if count > 0
            end
            results.sort_by { |r| -r[:updated_at].to_f }.map { |r| r.except(:updated_at) }
          else
            raise ArgumentError, "Invalid output_mode: #{output_mode}. Must be 'files_with_matches', 'content', or 'count'"
          end
        end

        # Clear all entries
        #
        # @return [void]
        def clear
          @mutex.synchronize do
            @entries.clear
            @total_size = 0
          end
        end

        # Get current total size
        #
        # @return [Integer] Total size in bytes
        attr_reader :total_size

        # Get number of entries
        #
        # @return [Integer] Number of entries
        def size
          @entries.size
        end

        # Get all entries with content for snapshot
        #
        # Thread-safe method that returns a copy of all entries.
        # Used by snapshot/restore functionality.
        #
        # @return [Hash] { path => Entry }
        def all_entries
          @mutex.synchronize do
            @entries.dup
          end
        end

        # Restore entries from snapshot
        #
        # Restores entries directly without using write() to preserve timestamps.
        # This ensures entry ordering and metadata accuracy after restore.
        #
        # @param entries_data [Hash] { path => { content:, title:, updated_at:, size: } }
        # @return [void]
        def restore_entries(entries_data)
          @mutex.synchronize do
            entries_data.each do |path, data|
              # Handle both symbol and string keys from JSON
              content = data[:content] || data["content"]
              title = data[:title] || data["title"]
              updated_at_str = data[:updated_at] || data["updated_at"]

              # Parse timestamp from ISO8601 string
              updated_at = Time.parse(updated_at_str)

              # Create entry with preserved timestamp
              entry = Entry.new(
                content: content,
                title: title,
                updated_at: updated_at,
                size: content.bytesize,
              )

              # Update storage
              @entries[path] = entry
              @total_size += entry.size
            end
          end
        end
      end
    end
  end
end
