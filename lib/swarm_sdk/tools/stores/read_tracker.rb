# frozen_string_literal: true

module SwarmSDK
  module Tools
    module Stores
      # ReadTracker manages read-file tracking for all agents with content digest verification
      #
      # This module maintains a global registry of which files each agent has read
      # during their conversation along with SHA256 digests of the content. This enables
      # enforcement of the "read-before-write" and "read-before-edit" rules that ensure
      # agents have context before modifying files, AND prevents editing files that have
      # changed externally since being read.
      #
      # Each agent maintains an independent map of read files to content digests.
      module ReadTracker
        @read_files = {} # { agent_id => { file_path => sha256_digest } }
        @mutex = Mutex.new

        class << self
          # Register that an agent has read a file with content digest
          #
          # @param agent_id [Symbol] The agent identifier
          # @param file_path [String] The absolute path to the file
          # @param content [String] The content that was read (used for digest calculation)
          # @return [String] The calculated SHA256 digest
          def register_read(agent_id, file_path, content)
            @mutex.synchronize do
              @read_files[agent_id] ||= {}
              expanded_path = File.expand_path(file_path)
              digest = Digest::SHA256.hexdigest(content)
              @read_files[agent_id][expanded_path] = digest
              digest
            end
          end

          # Check if an agent has read a file AND content hasn't changed
          #
          # Reads file the same way as Read tool's read_file_content:
          # try UTF-8 first, fall back to binary if encoding errors occur.
          #
          # @param agent_id [Symbol] The agent identifier
          # @param file_path [String] The absolute path to the file
          # @return [Boolean] true if agent read file and content matches
          def file_read?(agent_id, file_path)
            @mutex.synchronize do
              return false unless @read_files[agent_id]

              expanded_path = File.expand_path(file_path)
              stored_digest = @read_files[agent_id][expanded_path]
              return false unless stored_digest

              # Check if file still exists and matches stored digest
              return false unless File.exist?(expanded_path)

              current_content = read_file_content(expanded_path)
              current_digest = Digest::SHA256.hexdigest(current_content)
              current_digest == stored_digest
            rescue Errno::ENOENT
              false
            end
          end

          # Get all read files with digests for snapshot
          #
          # @param agent_id [Symbol] The agent identifier
          # @return [Hash] { file_path => digest }
          def get_read_files(agent_id)
            @mutex.synchronize do
              @read_files[agent_id]&.dup || {}
            end
          end

          # Restore read files with digests from snapshot
          #
          # @param agent_id [Symbol] The agent identifier
          # @param files_with_digests [Hash] { file_path => digest }
          # @return [void]
          def restore_read_files(agent_id, files_with_digests)
            @mutex.synchronize do
              @read_files[agent_id] = files_with_digests.dup
            end
          end

          # Clear read history for an agent (useful for testing)
          #
          # @param agent_id [Symbol] The agent identifier
          def clear(agent_id)
            @mutex.synchronize do
              @read_files.delete(agent_id)
            end
          end

          # Clear all read history (useful for testing)
          def clear_all
            @mutex.synchronize do
              @read_files.clear
            end
          end

          private

          # Read file content consistently with Read tool's read_file_content
          #
          # Tries UTF-8 encoding first, falls back to binary read if encoding
          # errors occur or content has invalid encoding.
          #
          # @param file_path [String] The absolute path to the file
          # @return [String] The file content
          def read_file_content(file_path)
            content = File.read(file_path, encoding: "UTF-8")
            return File.binread(file_path) unless content.valid_encoding?

            content
          rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
            File.binread(file_path)
          end
        end
      end
    end
  end
end
