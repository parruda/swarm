# frozen_string_literal: true

module SwarmCLI
  module Commands
    # Run command executes a swarm with the given configuration and prompt.
    #
    # Supports both YAML (.yml, .yaml) and Ruby DSL (.rb) configuration files.
    #
    # Usage:
    #   swarm run config.yml -p "Build a REST API"
    #   swarm run config.rb -p "Build a REST API"
    #   echo "Build a REST API" | swarm run config.yml
    #   swarm run config.yml -p "Task" --output-format json
    #
    class Run
      attr_reader :options

      def initialize(options)
        @options = options
      end

      def execute
        # Validate options
        options.validate!

        # Load swarm configuration
        swarm = load_swarm

        # Check if interactive mode (no prompt provided and stdin is a tty)
        if options.interactive_mode?
          run_interactive_mode(swarm)
        else
          run_non_interactive_mode(swarm)
        end
      rescue SwarmSDK::ConfigurationError, SwarmSDK::AgentNotFoundError => e
        # Configuration errors - show user-friendly message
        handle_error(e, formatter: create_formatter)
        exit(1)
      rescue SwarmCLI::ExecutionError => e
        # CLI-specific errors (e.g., missing prompt)
        handle_error(e, formatter: create_formatter)
        exit(1)
      rescue Interrupt
        # User cancelled (Ctrl+C)
        $stderr.puts "\n\nExecution cancelled by user"
        exit(130)
      rescue StandardError => e
        # Unexpected errors
        handle_error(e, formatter: create_formatter)
        exit(1)
      end

      private

      def run_interactive_mode(swarm)
        # Launch the interactive REPL with optional initial message
        initial_message = options.initial_message
        repl = SwarmCLI::InteractiveREPL.new(
          swarm: swarm,
          options: options,
          initial_message: initial_message,
        )
        repl.run
        exit(0)
      end

      def run_non_interactive_mode(swarm)
        # Create formatter based on output format
        formatter = create_formatter

        # Get prompt text
        prompt = options.prompt_text

        # Notify formatter of start
        formatter.on_start(
          config_path: options.config_file,
          swarm_name: swarm.name,
          lead_agent: swarm.lead_agent,
          prompt: prompt,
        )

        # Emit validation warnings before execution
        emit_validation_warnings(swarm, formatter)

        # Execute swarm with logging
        start_time = Time.now
        result = swarm.execute(prompt) do |log_entry|
          # Skip model warnings - already emitted above
          next if log_entry[:type] == "model_lookup_warning"

          formatter.on_log(log_entry)
        end

        # Check for errors
        if result.failure?
          duration = Time.now - start_time
          formatter.on_error(error: result.error, duration: duration)
          exit(1)
        end

        # Notify formatter of success
        formatter.on_success(result: result)

        # Exit successfully
        exit(0)
      end

      def load_swarm
        config_path = options.config_file

        ConfigLoader.load(config_path)
      rescue SwarmCLI::ConfigurationError => e
        # ConfigLoader already provides good context
        raise SwarmCLI::ExecutionError, e.message
      rescue SwarmSDK::ConfigurationError => e
        # SDK errors - add context
        raise SwarmCLI::ExecutionError, "Configuration error: #{e.message}"
      end

      def create_formatter
        case options.output_format
        when "json"
          Formatters::JsonFormatter.new
        when "human"
          Formatters::HumanFormatter.new(
            quiet: options.quiet?,
            truncate: options.truncate?,
            verbose: options.verbose?,
          )
        else
          raise SwarmCLI::ExecutionError, "Unknown output format: #{options.output_format}"
        end
      end

      def emit_validation_warnings(swarm, formatter)
        # Setup temporary logging to capture and emit warnings
        SwarmSDK::LogCollector.subscribe(filter: { type: "model_lookup_warning" }) do |log_entry|
          formatter.on_log(log_entry)
        end

        SwarmSDK::LogStream.emitter = SwarmSDK::LogCollector

        # Emit validation warnings as log events
        swarm.emit_validation_warnings

        # Clean up
        SwarmSDK::LogCollector.reset!
        SwarmSDK::LogStream.reset!
      rescue StandardError
        # Ignore errors during validation emission
        begin
          SwarmSDK::LogCollector.reset!
        rescue
          nil
        end
        begin
          SwarmSDK::LogStream.reset!
        rescue
          nil
        end
      end

      def handle_error(error, formatter: nil)
        if formatter
          formatter.on_error(error: error)
        else
          # Fallback if formatter not available
          $stderr.puts "Error: #{error.message}"
        end
      end
    end
  end
end
