# frozen_string_literal: true

module SwarmSDK
  module Tools
    module Stores
      # Abstract base class for hierarchical key-value storage with metadata
      #
      # Provides session-scoped storage for agents with path-based organization.
      # Subclasses implement persistence behavior (volatile vs persistent).
      #
      # Features:
      # - Path-based: Hierarchical organization using file-path-like addresses
      # - Metadata-rich: Stores content + title + timestamp + size
      # - Search capabilities: Glob patterns and grep-style content search
      # - Thread-safe: Mutex-protected operations
      class Storage
        # Represents a single storage entry with metadata
        Entry = Struct.new(:content, :title, :updated_at, :size, keyword_init: true)

        # Initialize storage
        #
        # Subclasses should call super() in their initialize method.
        # This base implementation does nothing - it exists only to satisfy RuboCop.
        def initialize
          # Base class initialization - subclasses implement their own logic
        end

        # Write content to storage
        #
        # @param file_path [String] Path to store content
        # @param content [String] Content to store
        # @param title [String] Brief title describing the content
        # @raise [ArgumentError] If size limits are exceeded
        # @return [Entry] The created entry
        def write(file_path:, content:, title:)
          raise NotImplementedError, "Subclass must implement #write"
        end

        # Read content from storage
        #
        # @param file_path [String] Path to read from
        # @raise [ArgumentError] If path not found
        # @return [String] Content at the path
        def read(file_path:)
          raise NotImplementedError, "Subclass must implement #read"
        end

        # Delete a specific entry
        #
        # @param file_path [String] Path to delete
        # @raise [ArgumentError] If path not found
        # @return [void]
        def delete(file_path:)
          raise NotImplementedError, "Subclass must implement #delete"
        end

        # List entries, optionally filtered by prefix
        #
        # @param prefix [String, nil] Filter by path prefix
        # @return [Array<Hash>] Array of entry metadata (path, title, size, updated_at)
        def list(prefix: nil)
          raise NotImplementedError, "Subclass must implement #list"
        end

        # Search entries by glob pattern
        #
        # @param pattern [String] Glob pattern (e.g., "**/*.txt", "parallel/*/task_*")
        # @return [Array<Hash>] Array of matching entry metadata, sorted by most recent first
        def glob(pattern:)
          raise NotImplementedError, "Subclass must implement #glob"
        end

        # Search entry content by pattern
        #
        # @param pattern [String] Regular expression pattern to search for
        # @param case_insensitive [Boolean] Whether to perform case-insensitive search
        # @param output_mode [String] Output mode: "files_with_matches" (default), "content", or "count"
        # @return [Array<Hash>, String] Results based on output_mode
        def grep(pattern:, case_insensitive: false, output_mode: "files_with_matches")
          raise NotImplementedError, "Subclass must implement #grep"
        end

        # Clear all entries
        #
        # @return [void]
        def clear
          raise NotImplementedError, "Subclass must implement #clear"
        end

        # Get current total size
        #
        # @return [Integer] Total size in bytes
        def total_size
          raise NotImplementedError, "Subclass must implement #total_size"
        end

        # Get number of entries
        #
        # @return [Integer] Number of entries
        def size
          raise NotImplementedError, "Subclass must implement #size"
        end

        protected

        # Format bytes to human-readable size
        #
        # @param bytes [Integer] Number of bytes
        # @return [String] Formatted size (e.g., "1.5MB", "500.0KB")
        def format_bytes(bytes)
          if bytes >= 1_000_000
            "#{(bytes.to_f / 1_000_000).round(1)}MB"
          elsif bytes >= 1_000
            "#{(bytes.to_f / 1_000).round(1)}KB"
          else
            "#{bytes}B"
          end
        end

        # Convert glob pattern to regex
        #
        # @param pattern [String] Glob pattern
        # @return [Regexp] Regular expression
        def glob_to_regex(pattern)
          # Escape special regex characters except glob wildcards
          escaped = Regexp.escape(pattern)

          # Convert glob wildcards to regex
          # ** matches any number of directories (including zero)
          escaped = escaped.gsub('\*\*', ".*")
          # * matches anything except directory separator
          escaped = escaped.gsub('\*', "[^/]*")
          # ? matches single character except directory separator
          escaped = escaped.gsub('\?', "[^/]")

          # Anchor to start and end
          Regexp.new("\\A#{escaped}\\z")
        end
      end
    end
  end
end
