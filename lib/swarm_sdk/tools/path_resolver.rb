# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Shared path resolution and agent context logic for file tools
    #
    # This module provides:
    # - Path resolution (relative to agent's working directory)
    # - Agent context initialization (agent_name, directory expansion)
    # - Standard error message formatting
    #
    # Tools resolve relative paths against the agent's directory.
    # Absolute paths are used as-is.
    #
    # @example
    #   class Read < RubyLLM::Tool
    #     include PathResolver
    #
    #     def initialize(agent_name:, directory:)
    #       super()
    #       initialize_agent_context(agent_name: agent_name, directory: directory)
    #     end
    #
    #     def execute(file_path:)
    #       resolved_path = resolve_path(file_path)
    #       File.read(resolved_path)
    #     rescue StandardError => e
    #       error("Failed to read: #{e.message}")
    #     end
    #   end
    module PathResolver
      # Agent context attributes
      # @return [Symbol] The agent identifier
      attr_reader :agent_name

      # @return [String] Absolute path to agent's working directory
      attr_reader :directory

      private

      # Initialize agent context for file tools
      #
      # Sets up the common agent context needed by file tools:
      # - Normalizes agent_name to symbol
      # - Expands directory to absolute path
      #
      # @param agent_name [Symbol, String] The agent identifier
      # @param directory [String] Agent's working directory (will be expanded)
      # @return [void]
      def initialize_agent_context(agent_name:, directory:)
        @agent_name = agent_name.to_sym
        @directory = File.expand_path(directory)
      end

      # Resolve a path relative to the agent's directory
      #
      # - Absolute paths (starting with /) are returned as-is
      # - Relative paths are resolved against @directory
      #
      # @param path [String] Path to resolve (relative or absolute)
      # @return [String] Absolute path
      # @raise [RuntimeError] If @directory not set (developer error)
      def resolve_path(path)
        raise "PathResolver requires @directory to be set" unless @directory

        return path if path.to_s.start_with?("/")

        File.expand_path(path, @directory)
      end

      # Format a validation error response
      #
      # Used for input validation failures (missing required params, invalid formats, etc.)
      #
      # @param message [String] Error description
      # @return [String] Formatted error message wrapped in tool_use_error tags
      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end

      # Format a general error response
      #
      # Used for runtime errors (permission denied, file not found, etc.)
      #
      # @param message [String] Error description
      # @return [String] Formatted error message prefixed with "Error:"
      def error(message)
        "Error: #{message}"
      end
    end
  end
end
