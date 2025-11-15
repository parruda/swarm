# frozen_string_literal: true

module SwarmCLI
  # ConfigLoader handles loading swarm configurations from both YAML and Ruby DSL files.
  #
  # Supports:
  # - YAML files (.yml, .yaml) - loaded via SwarmSDK.load_file
  # - Ruby DSL files (.rb) - executed and expected to return a SwarmSDK::Swarm or SwarmSDK::Workflow instance
  #
  # @example Load YAML config
  #   swarm = ConfigLoader.load("config.yml")
  #
  # @example Load Ruby DSL config
  #   swarm = ConfigLoader.load("config.rb")
  #
  class ConfigLoader
    class << self
      # Load a swarm configuration from file (YAML or Ruby DSL)
      #
      # Detects file type by extension:
      # - .yml, .yaml -> Load as YAML using SwarmSDK.load_file
      # - .rb -> Execute as Ruby DSL and expect SwarmSDK::Swarm or SwarmSDK::Workflow instance
      #
      # @param path [String, Pathname] Path to configuration file
      # @return [SwarmSDK::Swarm, SwarmSDK::Workflow] Configured swarm or workflow instance
      # @raise [SwarmCLI::ConfigurationError] If file not found or invalid format
      def load(path)
        path = Pathname.new(path).expand_path

        unless path.exist?
          raise ConfigurationError, "Configuration file not found: #{path}"
        end

        case path.extname.downcase
        when ".yml", ".yaml"
          load_yaml(path)
        when ".rb"
          load_ruby_dsl(path)
        else
          raise ConfigurationError,
            "Unsupported configuration file format: #{path.extname}. " \
              "Supported formats: .yml, .yaml (YAML), .rb (Ruby DSL)"
        end
      end

      private

      # Load YAML configuration file
      #
      # @param path [Pathname] Path to YAML file
      # @return [SwarmSDK::Swarm] Configured swarm instance
      def load_yaml(path)
        SwarmSDK.load_file(path.to_s)
      rescue SwarmSDK::ConfigurationError => e
        # Re-raise with CLI context
        raise ConfigurationError, "Configuration error in #{path}: #{e.message}"
      end

      # Load Ruby DSL configuration file
      #
      # Executes the Ruby file in a clean binding and expects it to return
      # a SwarmSDK::Swarm or SwarmSDK::Workflow instance. The file should
      # use SwarmSDK.build or SwarmSDK.workflow or create a Swarm/Workflow instance directly.
      #
      # @param path [Pathname] Path to Ruby DSL file
      # @return [SwarmSDK::Swarm, SwarmSDK::Workflow] Configured swarm or workflow instance
      # @raise [ConfigurationError] If file doesn't return a valid instance
      def load_ruby_dsl(path)
        # Read the file content
        content = path.read

        # Execute in a clean binding with SwarmSDK available
        # This allows the DSL file to use SwarmSDK.build or SwarmSDK.workflow directly
        result = eval(content, binding, path.to_s, 1) # rubocop:disable Security/Eval

        # Validate result is a Swarm or Workflow instance
        # Both have the same execute(prompt) interface
        unless result.is_a?(SwarmSDK::Swarm) || result.is_a?(SwarmSDK::Workflow)
          raise ConfigurationError,
            "Ruby DSL file must return a SwarmSDK::Swarm or SwarmSDK::Workflow instance. " \
              "Got: #{result.class}. " \
              "Use: SwarmSDK.build { ... } or SwarmSDK.workflow { ... }"
        end

        result
      rescue SwarmSDK::ConfigurationError => e
        # Re-raise SDK configuration errors with CLI context
        raise ConfigurationError, "Configuration error in #{path}: #{e.message}"
      rescue SyntaxError => e
        # Ruby syntax errors
        raise ConfigurationError, "Syntax error in #{path}: #{e.message}"
      rescue StandardError => e
        # Other Ruby errors during execution
        raise ConfigurationError, "Error loading #{path}: #{e.message}"
      end
    end
  end
end
