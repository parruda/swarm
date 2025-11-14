# frozen_string_literal: true

module ClaudeSwarm
  class CLI < Thor
    include SystemUtils

    class << self
      def exit_on_failure?
        true
      end
    end

    desc "start [CONFIG_FILE]", "Start a Claude Swarm from configuration file"
    method_option :vibe,
      type: :boolean,
      default: false,
      desc: "Run with --dangerously-skip-permissions for all instances"
    method_option :prompt,
      aliases: "-p",
      type: :string,
      desc: "Prompt to pass to the main Claude instance (non-interactive mode)"
    method_option :interactive,
      aliases: "-i",
      type: :string,
      desc: "Initial prompt for interactive mode"
    method_option :stream_logs,
      type: :boolean,
      default: false,
      desc: "Stream session logs to stdout (only works with -p)"
    method_option :debug,
      type: :boolean,
      default: false,
      desc: "Enable debug output"
    method_option :worktree,
      type: :string,
      aliases: "-w",
      desc: "Create instances in Git worktrees with the given name (auto-generated if true)",
      banner: "[NAME]"
    method_option :session_id,
      type: :string,
      desc: "Use a specific session ID instead of generating one"
    method_option :root_dir,
      type: :string,
      desc: "Root directory for resolving relative paths (defaults to current directory)"
    def start(config_file = nil)
      # Determine root directory for this session
      root_dir = File.expand_path(options[:root_dir] || Dir.pwd)

      # Resolve config path relative to root directory
      config_path = config_file || "claude-swarm.yml"
      config_path = File.expand_path(config_path, root_dir)

      unless File.exist?(config_path)
        error("Configuration file not found: #{config_path}")
        exit(1)
      end

      say("Starting Claude Swarm from #{config_path}...") unless options[:prompt]

      # Validate stream_logs option
      if options[:stream_logs] && !options[:prompt]
        error("--stream-logs can only be used with -p/--prompt")
        exit(1)
      end

      # Validate conflicting options
      if options[:prompt] && options[:interactive]
        error("Cannot use both -p/--prompt and -i/--interactive")
        exit(1)
      end

      begin
        config = Configuration.new(config_path, base_dir: root_dir, options: options)
        generator = McpGenerator.new(config, vibe: options[:vibe])
        orchestrator = Orchestrator.new(
          config,
          generator,
          vibe: options[:vibe],
          prompt: options[:prompt],
          interactive_prompt: options[:interactive],
          stream_logs: options[:stream_logs],
          debug: options[:debug],
          worktree: options[:worktree],
          session_id: options[:session_id],
        )
        orchestrator.start
      rescue Error => e
        error(e.message)
        exit(1)
      rescue StandardError => e
        error("Unexpected error: #{e.message}")
        error(e.backtrace.join("\n")) if options[:verbose]
        exit(1)
      end
    end

    desc "mcp-serve", "Start an MCP server for a Claude instance"
    method_option :name,
      aliases: "-n",
      type: :string,
      required: true,
      desc: "Instance name"
    method_option :directory,
      aliases: "-d",
      type: :string,
      required: true,
      desc: "Working directory for the instance"
    method_option :directories,
      type: :array,
      desc: "All directories (including main directory) for the instance"
    method_option :model,
      aliases: "-m",
      type: :string,
      required: true,
      desc: "Claude model to use (e.g., opus, sonnet)"
    method_option :prompt,
      aliases: "-p",
      type: :string,
      desc: "System prompt for the instance"
    method_option :description,
      type: :string,
      desc: "Description of the instance's role"
    method_option :allowed_tools,
      aliases: "-t",
      type: :array,
      desc: "Allowed tools for the instance"
    method_option :disallowed_tools,
      type: :array,
      desc: "Disallowed tools for the instance"
    method_option :connections,
      type: :array,
      desc: "Connections to other instances"
    method_option :mcp_config_path,
      type: :string,
      desc: "Path to MCP configuration file"
    method_option :debug,
      type: :boolean,
      default: false,
      desc: "Enable debug output"
    method_option :vibe,
      type: :boolean,
      default: false,
      desc: "Run with --dangerously-skip-permissions"
    method_option :calling_instance,
      type: :string,
      required: true,
      desc: "Name of the instance that launched this MCP server"
    method_option :calling_instance_id,
      type: :string,
      desc: "Unique ID of the instance that launched this MCP server"
    method_option :instance_id,
      type: :string,
      desc: "Unique ID of this instance"
    method_option :claude_session_id,
      type: :string,
      desc: "Claude session ID to resume"
    method_option :provider,
      type: :string,
      desc: "Provider to use (claude or openai)"
    method_option :temperature,
      type: :numeric,
      desc: "Temperature for OpenAI models"
    method_option :api_version,
      type: :string,
      desc: "API version for OpenAI (chat_completion or responses)"
    method_option :openai_token_env,
      type: :string,
      desc: "Environment variable name for OpenAI API key"
    method_option :base_url,
      type: :string,
      desc: "Base URL for OpenAI API"
    method_option :reasoning_effort,
      type: :string,
      desc: "Reasoning effort for OpenAI models"
    method_option :zdr,
      type: :boolean,
      default: false,
      desc: "Enable ZDR for OpenAI models"
    def mcp_serve
      # Validate reasoning_effort if provided
      if options[:reasoning_effort]
        # Only validate if provider is openai (or not specified, since it could be set elsewhere)
        if options[:provider] && options[:provider] != "openai"
          error("reasoning_effort is only supported for OpenAI models")
          exit(1)
        end

        # Validate the value
        unless ClaudeSwarm::Configuration::VALID_REASONING_EFFORTS.include?(options[:reasoning_effort])
          error("reasoning_effort must be 'low', 'medium', or 'high'")
          exit(1)
        end
      end

      instance_config = {
        name: options[:name],
        directory: options[:directory],
        directories: options[:directories] || [options[:directory]],
        model: options[:model],
        prompt: options[:prompt],
        description: options[:description],
        allowed_tools: options[:allowed_tools] || [],
        disallowed_tools: options[:disallowed_tools] || [],
        connections: options[:connections] || [],
        mcp_config_path: options[:mcp_config_path],
        vibe: options[:vibe] || false,
        instance_id: options[:instance_id],
        claude_session_id: options[:claude_session_id],
        provider: options[:provider],
        temperature: options[:temperature],
        api_version: options[:api_version],
        openai_token_env: options[:openai_token_env],
        base_url: options[:base_url],
        reasoning_effort: options[:reasoning_effort],
        zdr: options[:zdr],
      }

      begin
        server = ClaudeMcpServer.new(
          instance_config,
          calling_instance: options[:calling_instance],
          calling_instance_id: options[:calling_instance_id],
          debug: options[:debug],
        )
        server.start
      rescue StandardError => e
        error("Error starting MCP server: #{e.message}")
        error(e.backtrace.join("\n")) if options[:debug]
        exit(1)
      end
    end

    desc "init", "Initialize a new claude-swarm.yml configuration file"
    method_option :force,
      aliases: "-f",
      type: :boolean,
      default: false,
      desc: "Overwrite existing configuration file"
    def init
      config_path = "claude-swarm.yml"

      if File.exist?(config_path) && !options[:force]
        error("Configuration file already exists: #{config_path}")
        error("Use --force to overwrite")
        exit(1)
      end

      template = <<~YAML
        version: 1
        swarm:
          name: "Swarm Name"
          main: lead_developer
          # before:  # Optional: commands to run before launching swarm (executed in sequence)
          #   - "echo 'Setting up environment...'"
          #   - "npm install"
          #   - "docker-compose up -d"
          instances:
            lead_developer:
              description: "Lead developer who coordinates the team and makes architectural decisions"
              directory: .
              model: sonnet
              prompt: |
                You are the lead developer coordinating the team
              allowed_tools: [Read, Edit, Bash, Write]
              # connections: [frontend_dev, backend_dev]

            # Example instances (uncomment and modify as needed):

            # frontend_dev:
            #   description: "Frontend developer specializing in React and modern web technologies"
            #   directory: ./frontend
            #   model: sonnet
            #   prompt: |
            #     You specialize in frontend development with React, TypeScript, and modern web technologies
            #   allowed_tools: [Read, Edit, Write, "Bash(npm:*)", "Bash(yarn:*)", "Bash(pnpm:*)"]

            # backend_dev:
            #   description: |
            #     Backend developer focusing on APIs, databases, and server architecture
            #   directory: ../other-app/backend
            #   model: sonnet
            #   prompt: |
            #     You specialize in backend development, APIs, databases, and server architecture
            #   allowed_tools: [Read, Edit, Write, Bash]

            # devops_engineer:
            #   description: "DevOps engineer managing infrastructure, CI/CD, and deployments"
            #   directory: .
            #   model: sonnet
            #   prompt: |
            #     You specialize in infrastrujcture, CI/CD, containerization, and deployment
            #   allowed_tools: [Read, Edit, Write, "Bash(docker:*)", "Bash(kubectl:*)", "Bash(terraform:*)"]

            # qa_engineer:
            #   description: "QA engineer ensuring quality through comprehensive testing"
            #   directory: ./tests
            #   model: sonnet
            #   prompt: |
            #     You specialize in testing, quality assurance, and test automation
            #   allowed_tools: [Read, Edit, Write, Bash]
      YAML

      File.write(config_path, template)
      say("Created #{config_path}", :green)
      say("Edit this file to configure your swarm, then run 'claude-swarm' to start")
    end

    desc "generate", "Launch Claude to help generate a swarm configuration interactively"
    method_option :output,
      aliases: "-o",
      type: :string,
      desc: "Output file path for the generated configuration"
    method_option :model,
      aliases: "-m",
      type: :string,
      default: "sonnet",
      desc: "Claude model to use for generation"
    def generate
      # Check if claude command exists
      begin
        system!("command -v claude > /dev/null 2>&1")
      rescue Error
        error("Claude CLI is not installed or not in PATH")
        error("To install Claude CLI, visit: https://docs.anthropic.com/en/docs/claude-code")
        exit(1)
      end

      # Read README for context about claude-swarm capabilities
      readme_path = File.join(__dir__, "../../README.md")
      readme_content = File.exist?(readme_path) ? File.read(readme_path) : ""

      # Build the pre-prompt
      preprompt = build_generation_prompt(readme_content, options[:output])

      # Launch Claude in interactive mode with the initial prompt
      cmd = [
        "claude",
        "--model",
        options[:model],
        preprompt,
      ]

      # Execute and let the user take over
      exec(*cmd)
    end

    desc "version", "Show Claude Swarm version"
    def version
      say("Claude Swarm #{VERSION}")
    end

    desc "ps", "List running Claude Swarm sessions"
    def ps
      Commands::Ps.new.execute
    end

    desc "show SESSION_ID", "Show detailed session information"
    def show(session_id)
      Commands::Show.new.execute(session_id)
    end

    desc "clean", "Remove stale session symlinks and orphaned worktrees"
    method_option :days,
      aliases: "-d",
      type: :numeric,
      default: 7,
      desc: "Remove sessions older than N days"
    def clean
      # Clean stale symlinks
      cleaned_symlinks = clean_stale_symlinks(options[:days])

      # Clean orphaned worktrees
      cleaned_worktrees = clean_orphaned_worktrees(options[:days])

      if cleaned_symlinks.positive? || cleaned_worktrees.positive?
        say("Cleaned #{cleaned_symlinks} stale symlink#{"s" unless cleaned_symlinks == 1}", :green)
        say("Cleaned #{cleaned_worktrees} orphaned worktree#{"s" unless cleaned_worktrees == 1}", :green)
      else
        say("No cleanup needed", :green)
      end
    end

    desc "restore SESSION_ID", "Restore a previous session by ID"
    def restore(session_id)
      restore_session(session_id)
    end

    desc "watch SESSION_ID", "Watch session logs"
    method_option :lines,
      aliases: "-n",
      type: :numeric,
      default: 100,
      desc: "Number of lines to show initially"
    def watch(session_id)
      # Find session path
      run_symlink = ClaudeSwarm.joined_run_dir(session_id)
      session_path = if File.symlink?(run_symlink)
        File.readlink(run_symlink)
      else
        # Search in sessions directory
        Dir.glob(ClaudeSwarm.joined_sessions_dir("*", "*")).find do |path|
          File.basename(path) == session_id
        end
      end

      unless session_path && Dir.exist?(session_path)
        error("Session not found: #{session_id}")
        exit(1)
      end

      log_file = File.join(session_path, "session.log")
      unless File.exist?(log_file)
        error("Log file not found for session: #{session_id}")
        exit(1)
      end

      exec("tail", "-f", "-n", options[:lines].to_s, log_file)
    end

    desc "list-sessions", "List all available Claude Swarm sessions"
    method_option :limit,
      aliases: "-l",
      type: :numeric,
      default: 10,
      desc: "Maximum number of sessions to display"
    def list_sessions
      sessions_dir = ClaudeSwarm.joined_sessions_dir
      unless Dir.exist?(sessions_dir)
        say("No sessions found", :yellow)
        return
      end

      # Find all sessions with MCP configs
      sessions = []
      Dir.glob("#{sessions_dir}/*/*/*.mcp.json").each do |mcp_path|
        session_path = File.dirname(mcp_path)
        session_id = File.basename(session_path)
        project_name = File.basename(File.dirname(session_path))

        # Skip if we've already processed this session
        next if sessions.any? { |s| s[:path] == session_path }

        # Try to load session info
        config_file = File.join(session_path, "config.yml")
        next unless File.exist?(config_file)

        # Load the config to get swarm info
        begin
          config_data = YamlLoader.load_config_file(config_file)
          swarm_name = config_data.dig("swarm", "name") || "Unknown"
          main_instance = config_data.dig("swarm", "main") || "Unknown"
        rescue ClaudeSwarm::Error => e
          # Warn about corrupted config files but continue
          say_error("⚠️ Skipping session #{session_id} - #{e.message}")
          next
        end

        mcp_files = Dir.glob(File.join(session_path, "*.mcp.json"))

        # Get creation time from directory
        created_at = File.stat(session_path).ctime

        sessions << {
          path: session_path,
          id: session_id,
          project: project_name,
          created_at: created_at,
          main_instance: main_instance,
          instances_count: mcp_files.size,
          swarm_name: swarm_name,
          config_path: config_file,
        }
      rescue StandardError
        # Skip invalid manifests
        next
      end

      if sessions.empty?
        say("No sessions found", :yellow)
        return
      end

      # Sort by creation time (newest first)
      sessions.sort_by! { |s| -s[:created_at].to_i }
      sessions = sessions.first(options[:limit])

      # Display sessions
      say("\nAvailable sessions (newest first):\n", :bold)
      sessions.each do |session|
        say("\n#{session[:project]}/#{session[:id]}", :green)
        say("  Created: #{session[:created_at].strftime("%Y-%m-%d %H:%M:%S")}")
        say("  Main: #{session[:main_instance]}")
        say("  Instances: #{session[:instances_count]}")
        say("  Swarm: #{session[:swarm_name]}")
        say("  Config: #{session[:config_path]}", :cyan)
      end

      say("\nTo resume a session, run:", :bold)
      say("  claude-swarm restore <session-id>", :cyan)
    end

    default_task :start

    private

    def error(message)
      $stderr.puts(Thor::Shell::Color.new.set_color(message, :red))
    end

    def restore_session(session_id)
      say("Restoring session: #{session_id}", :green)

      # Find the session path
      session_path = find_session_path(session_id)
      unless session_path
        error("Session not found: #{session_id}")
        exit(1)
      end

      begin
        # Load session info from instance ID in MCP config
        mcp_files = Dir.glob(File.join(session_path, "*.mcp.json"))
        if mcp_files.empty?
          error("No MCP configuration files found in session")
          exit(1)
        end

        # Load the configuration from the session directory
        config_file = File.join(session_path, "config.yml")

        unless File.exist?(config_file)
          error("Configuration file not found in session")
          exit(1)
        end

        # Load the original root directory from session
        root_dir_file = File.join(session_path, "root_directory")
        root_dir = if File.exist?(root_dir_file)
          original_dir = File.read(root_dir_file).strip
          if Dir.exist?(original_dir)
            say("Using original directory: #{original_dir}", :green) unless options[:prompt]
            original_dir
          else
            error("Original directory no longer exists: #{original_dir}")
            exit(1)
          end
        else
          # If no root_directory file, use current directory
          Dir.pwd
        end

        config = Configuration.new(config_file, base_dir: root_dir)

        # Load session metadata if it exists to check for worktree info
        session_metadata_file = File.join(session_path, "session_metadata.json")
        worktree_name = nil
        metadata = JsonHandler.parse_file(session_metadata_file)
        if metadata && metadata["worktree"] && metadata["worktree"]["enabled"]
          worktree_name = metadata["worktree"]["name"]
          say("Restoring with worktree: #{worktree_name}", :green) unless options[:prompt]
        end

        # Create orchestrator with restoration mode
        generator = McpGenerator.new(config, vibe: options[:vibe], restore_session_path: session_path)
        orchestrator = Orchestrator.new(
          config,
          generator,
          vibe: options[:vibe],
          prompt: options[:prompt],
          stream_logs: options[:stream_logs],
          debug: options[:debug],
          restore_session_path: session_path,
          worktree: worktree_name,
          session_id: options[:session_id],
        )
        orchestrator.start
      rescue StandardError => e
        error("Failed to restore session: #{e.message}")
        error(e.backtrace.join("\n")) if options[:debug]
        exit(1)
      end
    end

    def find_session_path(session_id)
      sessions_dir = ClaudeSwarm.joined_sessions_dir

      # Search for the session ID in all projects
      Dir.glob("#{sessions_dir}/*/#{session_id}").each do |path|
        config_path = File.join(path, "config.yml")
        return path if File.exist?(config_path)
      end

      nil
    end

    def clean_stale_symlinks(days)
      run_dir = ClaudeSwarm.joined_run_dir
      return 0 unless Dir.exist?(run_dir)

      cleaned = 0
      Dir.glob("#{run_dir}/*").each do |symlink|
        next unless File.symlink?(symlink)

        begin
          # Remove if target doesn't exist (stale)
          unless File.exist?(File.readlink(symlink))
            File.unlink(symlink)
            cleaned += 1
            next
          end

          # Remove if older than specified days
          if File.stat(symlink).mtime < Time.now - (days * 86_400)
            File.unlink(symlink)
            cleaned += 1
          end
        rescue StandardError
          # Skip problematic symlinks
        end
      end

      cleaned
    end

    def clean_orphaned_worktrees(days)
      worktrees_dir = ClaudeSwarm.joined_worktrees_dir
      return 0 unless Dir.exist?(worktrees_dir)

      sessions_dir = ClaudeSwarm.joined_sessions_dir
      cleaned = 0

      Dir.glob("#{worktrees_dir}/*").each do |session_worktree_dir|
        session_id = File.basename(session_worktree_dir)

        # Skip if session still exists
        next if Dir.glob("#{sessions_dir}/*/#{session_id}").any? { |path| File.exist?(File.join(path, "config.yml")) }

        # Check age of worktree directory
        begin
          if File.stat(session_worktree_dir).mtime < Time.now - (days * 86_400)
            # Remove all git worktrees in this session directory
            Dir.glob("#{session_worktree_dir}/*/*").each do |worktree_path|
              next unless File.directory?(worktree_path)

              # Try to find the git repo and remove the worktree properly
              git_dir = File.join(worktree_path, ".git")
              if File.exist?(git_dir)
                # Read the gitdir file to find the repo
                gitdir_content = File.read(git_dir).strip
                if gitdir_content.start_with?("gitdir:")
                  repo_git_path = gitdir_content.sub("gitdir: ", "")
                  # Extract repo path from .git/worktrees path
                  repo_path = repo_git_path.split("/.git/worktrees/").first

                  # Try to remove worktree via git
                  system!(
                    "git",
                    "-C",
                    repo_path,
                    "worktree",
                    "remove",
                    worktree_path,
                    "--force",
                    out: File::NULL,
                    err: File::NULL,
                  )
                end
              end

              # Force remove directory if it still exists
              FileUtils.rm_rf(worktree_path)
            end

            # Remove the session worktree directory
            FileUtils.rm_rf(session_worktree_dir)
            cleaned += 1
          end
        rescue StandardError => e
          say("Warning: Failed to clean worktree directory #{session_worktree_dir}: #{e.message}", :yellow) if options[:debug]
        end
      end

      cleaned
    end

    def build_generation_prompt(readme_content, output_file)
      template_path = File.expand_path("templates/generation_prompt.md.erb", __dir__)
      template = File.read(template_path)
      <<~PROMPT
        #{ERB.new(template, trim_mode: "-").result(binding)}

        Start the conversation by greeting the user and asking: 'What kind of project would you like to create a Claude Swarm for?'
        Say: 'I am ready to start'
      PROMPT
    end
  end
end
