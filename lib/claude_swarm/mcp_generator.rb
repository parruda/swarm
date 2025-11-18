# frozen_string_literal: true

module ClaudeSwarm
  class McpGenerator
    def initialize(configuration, vibe: false, restore_session_path: nil)
      @config = configuration
      @vibe = vibe
      @restore_session_path = restore_session_path
      @session_path = nil # Will be set when needed
      @instance_ids = {} # Store instance IDs for all instances
      @restore_states = {} # Store loaded state data during restoration
    end

    def generate_all
      ensure_swarm_directory

      if @restore_session_path
        # Load existing instance IDs and states from state files
        load_instance_states
      else
        # Generate new instance IDs
        @config.instances.each_key do |name|
          @instance_ids[name] = "#{name}_#{SecureRandom.hex(4)}"
        end
      end

      @config.instances.each do |name, instance|
        generate_mcp_config(name, instance)
      end
    end

    def mcp_config_path(instance_name)
      File.join(session_path, "#{instance_name}.mcp.json")
    end

    private

    def session_path
      @session_path ||= SessionPath.from_env
    end

    def ensure_swarm_directory
      # Session directory is already created by orchestrator
      # Just ensure it exists
      SessionPath.ensure_directory(session_path)
    end

    def generate_mcp_config(name, instance)
      mcp_servers = {}

      # Add configured MCP servers
      instance[:mcps].each do |mcp|
        mcp_servers[mcp["name"]] = build_mcp_server_config(mcp)
      end

      # Add connection MCPs for other instances
      instance[:connections].each do |connection_name|
        connected_instance = @config.instances[connection_name]
        mcp_servers[connection_name] = build_instance_mcp_config(
          connection_name,
          connected_instance,
          calling_instance: name,
          calling_instance_id: @instance_ids[name],
        )
      end

      # Add Claude tools MCP server for OpenAI instances
      mcp_servers["claude_tools"] = build_claude_tools_mcp_config if instance[:provider] == "openai"

      config = {
        "instance_id" => @instance_ids[name],
        "instance_name" => name,
        "mcpServers" => mcp_servers,
      }

      JsonHandler.write_file!(mcp_config_path(name), config)
    end

    def build_mcp_server_config(mcp)
      case mcp["type"]
      when "stdio"
        {
          "type" => "stdio",
          "command" => mcp["command"],
          "args" => mcp["args"] || [],
        }.tap do |config|
          config["env"] = mcp["env"] if mcp["env"]
        end
      when "sse", "http"
        {
          "type" => mcp["type"],
          "url" => mcp["url"],
        }.tap do |config|
          config["headers"] = mcp["headers"] if mcp["headers"]
        end
      end
    end

    def build_claude_tools_mcp_config
      # Build environment for claude mcp serve by excluding Ruby/Bundler-specific variables
      # This preserves all system variables while removing Ruby contamination
      clean_env = ENV.to_h.reject do |key, _|
        key.start_with?("BUNDLE_") ||
          key.start_with?("RUBY") ||
          key.start_with?("GEM_") ||
          key == "RUBYOPT" ||
          key == "RUBYLIB"
      end

      {
        "type" => "stdio",
        "command" => "claude",
        "args" => ["mcp", "serve"],
        "env" => clean_env,
      }
    end

    def build_instance_mcp_config(name, instance, calling_instance:, calling_instance_id:)
      # Get the path to the claude-swarm executable
      exe_path = "claude-swarm"

      # Build command-line arguments for Thor
      args = [
        "mcp-serve",
        "--name",
        name,
        "--directory",
        instance[:directory],
        "--model",
        instance[:model],
      ]

      # Add directories array if we have multiple directories
      args.push("--directories", *instance[:directories]) if instance[:directories] && instance[:directories].size > 1

      # Add optional arguments
      # Handle prompt_file by reading the file contents
      if instance[:prompt_file]
        prompt_file_path = File.join(@config.root_directory, instance[:prompt_file])
        if File.exist?(prompt_file_path)
          prompt_content = File.read(prompt_file_path)
          args.push("--prompt", prompt_content)
        end
      elsif instance[:prompt]
        args.push("--prompt", instance[:prompt])
      end

      args.push("--description", instance[:description]) if instance[:description]

      args.push("--allowed-tools", instance[:allowed_tools].join(",")) if instance[:allowed_tools] && !instance[:allowed_tools].empty?

      args.push("--disallowed-tools", instance[:disallowed_tools].join(",")) if instance[:disallowed_tools] && !instance[:disallowed_tools].empty?

      args.push("--connections", instance[:connections].join(",")) if instance[:connections] && !instance[:connections].empty?

      args.push("--mcp-config-path", mcp_config_path(name))

      args.push("--calling-instance", calling_instance) if calling_instance

      args.push("--calling-instance-id", calling_instance_id) if calling_instance_id

      args.push("--instance-id", @instance_ids[name]) if @instance_ids[name]

      args.push("--vibe") if @vibe || instance[:vibe]

      # Add provider-specific parameters
      if instance[:provider]
        args.push("--provider", instance[:provider])

        # Add OpenAI-specific parameters
        if instance[:provider] == "openai"
          args.push("--reasoning-effort", instance[:reasoning_effort]) if instance[:reasoning_effort]
          args.push("--temperature", instance[:temperature].to_s) if instance[:temperature]
          args.push("--api-version", instance[:api_version]) if instance[:api_version]
          args.push("--openai-token-env", instance[:openai_token_env]) if instance[:openai_token_env]
          args.push("--base-url", instance[:base_url]) if instance[:base_url]
          args.push("--zdr", instance[:zdr].to_s) if instance.key?(:zdr)
        end
      end

      # Add claude session ID if restoring
      if @restore_states[name.to_s]
        claude_session_id = @restore_states[name.to_s]["claude_session_id"]
        args.push("--claude-session-id", claude_session_id) if claude_session_id
      end

      # Capture environment variables needed for running claude-swarm
      # We intentionally exclude Bundler variables to ensure we use the system-installed gem
      required_env = {}

      # Claude Swarm-specific variables (always needed)
      ENV.each do |k, v|
        required_env[k] = v if k.start_with?("CLAUDE_SWARM_")
      end

      # Ruby-specific variables that MCP servers need
      # Exclude RUBYOPT and RUBYLIB to avoid Bundler interference
      [
        "RUBY_ROOT",
        "RUBY_ENGINE",
        "RUBY_VERSION",
        "GEM_ROOT",
        "GEM_HOME",
        "GEM_PATH",
        "PATH",
      ].each do |key|
        required_env[key] = ENV[key] if ENV[key]
      end

      config = {
        "type" => "stdio",
        "command" => exe_path,
        "args" => args,
      }

      # Add required environment variables if any exist
      config["env"] = required_env unless required_env.empty?

      config
    end

    def load_instance_states
      state_dir = File.join(@restore_session_path, "state")
      return unless Dir.exist?(state_dir)

      Dir.glob(File.join(state_dir, "*.json")).each do |state_file|
        data = JsonHandler.parse_file!(state_file)
        instance_name = data["instance_name"]
        instance_id = data["instance_id"]

        # Check both string and symbol keys since config instances might have either
        if instance_name && (@config.instances.key?(instance_name) || @config.instances.key?(instance_name.to_sym))
          # Store with the same key type as in @config.instances
          key = @config.instances.key?(instance_name) ? instance_name : instance_name.to_sym
          @instance_ids[key] = instance_id
          @restore_states[instance_name] = data
        end
      rescue StandardError
        # Skip invalid state files
      end
    end
  end
end
