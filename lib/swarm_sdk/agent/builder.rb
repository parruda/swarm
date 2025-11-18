# frozen_string_literal: true

module SwarmSDK
  module Agent
    # Builder provides fluent API for configuring agents
    #
    # This class offers a Ruby DSL for defining agents with a clean, readable syntax.
    # It collects configuration and then adds the agent to the swarm.
    #
    # @example
    #   agent :backend do
    #     model "gpt-5"
    #     prompt "You build APIs"
    #     tools :Read, :Write, :Bash
    #
    #     hook :pre_tool_use, matcher: "Bash" do |ctx|
    #       SwarmSDK::Hooks::Result.halt("Blocked!") if dangerous?(ctx)
    #     end
    #   end
    class Builder
      # Expose default_permissions for Swarm::Builder to set from all_agents
      attr_writer :default_permissions

      # Expose mcp_servers for tests
      attr_reader :mcp_servers

      # Get tools list as array for validation
      #
      # @return [Array<Symbol>] List of tools
      def tools_list
        @tools.to_a
      end

      def initialize(name)
        @name = name
        @description = nil
        @model = "gpt-5"
        @provider = nil
        @base_url = nil
        @api_version = nil
        @context_window = nil
        @system_prompt = nil
        # Use Set for tools to automatically handle duplicates when tools() is called multiple times.
        # This ensures that if someone does: tools :Read; tools :Write; tools :Read
        # the final set contains only [:Read, :Write] without duplicates.
        # We convert to Array in to_definition for compatibility with Agent::Definition.
        @tools = Set.new
        @delegates_to = []
        @directory = "."
        @parameters = {}
        @headers = {}
        @timeout = nil
        @mcp_servers = []
        @disable_default_tools = nil # nil = include all default tools
        @bypass_permissions = false
        @coding_agent = nil # nil = not set (will default to false in Definition)
        @assume_model_exists = nil
        @hooks = []
        @permissions_config = {}
        @default_permissions = {} # Set by SwarmBuilder from all_agents
        @memory_config = nil
        @shared_across_delegations = nil # nil = not set (will default to false in Definition)
        @context_management_config = nil # Context management DSL hooks
      end

      # Set/get agent model
      def model(model_name = :__not_provided__)
        return @model if model_name == :__not_provided__

        @model = model_name
      end

      # Set/get provider
      def provider(provider_name = :__not_provided__)
        return @provider if provider_name == :__not_provided__

        @provider = provider_name
      end

      # Set/get base URL
      def base_url(url = :__not_provided__)
        return @base_url if url == :__not_provided__

        @base_url = url
      end

      # Set/get API version (OpenAI-compatible providers only)
      def api_version(version = :__not_provided__)
        return @api_version if version == :__not_provided__

        @api_version = version
      end

      # Set/get explicit context window override
      def context_window(tokens = :__not_provided__)
        return @context_window if tokens == :__not_provided__

        @context_window = tokens
      end

      # Set/get LLM parameters
      def parameters(params = :__not_provided__)
        return @parameters if params == :__not_provided__

        @parameters = params
      end

      # Set/get custom HTTP headers
      def headers(header_hash = :__not_provided__)
        return @headers if header_hash == :__not_provided__

        @headers = header_hash
      end

      # Set/get timeout
      def timeout(seconds = :__not_provided__)
        return @timeout if seconds == :__not_provided__

        @timeout = seconds
      end

      # Add an MCP server configuration
      #
      # @example stdio transport
      #   mcp_server :filesystem, type: :stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]
      #
      # @example SSE transport
      #   mcp_server :web, type: :sse, url: "https://example.com/mcp", headers: { authorization: "Bearer token" }
      #
      # @example HTTP/streamable transport
      #   mcp_server :api, type: :http, url: "https://api.example.com/mcp", timeout: 60
      def mcp_server(name, **options)
        server_config = { name: name }.merge(options)
        @mcp_servers << server_config
      end

      # Disable default tools
      #
      # @param value [Boolean, Array<Symbol>]
      #   - true: Disable ALL default tools
      #   - Array of symbols: Disable specific tools (e.g., [:Think, :TodoWrite])
      #
      # @example Disable all default tools
      #   disable_default_tools true
      #
      # @example Disable specific tools (array)
      #   disable_default_tools [:Think, :TodoWrite]
      #
      # @example Disable specific tools (separate arguments)
      #   disable_default_tools :Think, :TodoWrite
      def disable_default_tools(*tools)
        # Handle different argument forms
        @disable_default_tools = case tools.size
        when 0
          nil
        when 1
          # Single argument: could be true/false/array
          tools.first
        else
          # Multiple arguments: treat as array of tool names
          tools.map(&:to_sym)
        end
      end

      # Set bypass_permissions flag
      def bypass_permissions(enabled)
        @bypass_permissions = enabled
      end

      # Set coding_agent flag
      #
      # When true, includes the base system prompt for coding tasks.
      # When false (default), uses only the custom system prompt.
      #
      # @param enabled [Boolean] Whether to include base coding prompt
      # @return [void]
      #
      # @example
      #   coding_agent true  # Include base prompt for coding tasks
      def coding_agent(enabled)
        @coding_agent = enabled
      end

      # Set assume_model_exists flag
      def assume_model_exists(enabled)
        @assume_model_exists = enabled
      end

      # Set system prompt (matches YAML key)
      def system_prompt(text)
        @system_prompt = text
      end

      # Set description
      def description(text)
        @description = text
      end

      # Set or add tools
      #
      # Uses Set internally to automatically deduplicate tool names across multiple calls.
      # This allows calling tools() multiple times without worrying about duplicates.
      #
      # @param tool_names [Array<Symbol>] Tool names to add
      # @param include_default [Boolean] Whether to include default tools (Read, Grep, etc.)
      # @param replace [Boolean] If true, replaces existing tools instead of merging (default: false)
      #
      # @example Basic usage with defaults
      #   tools :Grep, :Read  # include_default: true is implicit
      #
      # @example Explicit tools only, no defaults
      #   tools :Grep, :Read, include_default: false
      #
      # @example Multiple calls (cumulative, automatic deduplication)
      #   tools :Read
      #   tools :Write, :Edit  # @tools now contains Set[:Read, :Write, :Edit]
      #   tools :Read          # Still Set[:Read, :Write, :Edit] - no duplicate
      #
      # @example Replace tools (for markdown overrides)
      #   tools :Read, :Write, replace: true  # Replaces all existing tools
      def tools(*tool_names, include_default: true, replace: false)
        @tools = Set.new if replace
        @tools.merge(tool_names.map(&:to_sym))
        # When include_default is false, disable all default tools
        @disable_default_tools = true unless include_default
      end

      # Add tools from all_agents configuration
      #
      # Used by Swarm::Builder to add all_agents tools.
      # Since we use Set, order doesn't matter and duplicates are handled automatically.
      #
      # @param tool_names [Array] Tool names to add
      # @return [void]
      def prepend_tools(*tool_names)
        @tools.merge(tool_names.map(&:to_sym))
      end

      # Set directory
      def directory(dir)
        @directory = dir
      end

      # Set delegation targets
      def delegates_to(*agent_names)
        @delegates_to.concat(agent_names)
      end

      # Add a hook (Ruby block OR shell command)
      #
      # @example Ruby block
      #   hook :pre_tool_use, matcher: "Bash" do |ctx|
      #     HookResult.halt("Blocked") if dangerous?(ctx)
      #   end
      #
      # @example Shell command
      #   hook :pre_tool_use, matcher: "Bash", command: "validate.sh"
      def hook(event, matcher: nil, command: nil, timeout: nil, &block)
        @hooks << {
          event: event,
          matcher: matcher,
          command: command,
          timeout: timeout,
          block: block,
        }
      end

      # Configure permissions for this agent
      #
      # @example
      #   permissions do
      #     Write.allow_paths "backend/**/*"
      #     Write.deny_paths "backend/secrets/**"
      #   end
      def permissions(&block)
        @permissions_config = PermissionsBuilder.build(&block)
      end

      # Configure delegation isolation mode
      #
      # @param enabled [Boolean] If true, allows sharing instances across delegations (old behavior)
      #                          If false (default), creates isolated instances per delegation
      # @return [self] Returns self for method chaining
      #
      # @example
      #   shared_across_delegations true  # Allow sharing (old behavior)
      def shared_across_delegations(enabled)
        @shared_across_delegations = enabled
        self
      end

      # Configure context management handlers
      #
      # Define custom handlers for context warning thresholds (60%, 80%, 90%).
      # Handlers receive a rich context object with message manipulation methods.
      # When a custom handler is registered, automatic compression is disabled
      # for that threshold, giving full control to the handler.
      #
      # @yield Context management DSL block
      # @return [void]
      #
      # @example Basic compression at 60%
      #   context_management do
      #     on :warning_60 do |ctx|
      #       ctx.compress_tool_results(keep_recent: 10)
      #     end
      #   end
      #
      # @example Multiple thresholds with different strategies
      #   context_management do
      #     on :warning_60 do |ctx|
      #       ctx.compress_tool_results(keep_recent: 15, truncate_to: 500)
      #     end
      #
      #     on :warning_80 do |ctx|
      #       ctx.prune_old_messages(keep_recent: 30)
      #       ctx.compress_tool_results(keep_recent: 5, truncate_to: 200)
      #     end
      #
      #     on :warning_90 do |ctx|
      #       ctx.log_action("emergency_pruning", remaining: ctx.tokens_remaining)
      #       ctx.prune_old_messages(keep_recent: 15)
      #     end
      #   end
      #
      # @example Conditional logic based on metrics
      #   context_management do
      #     on :warning_80 do |ctx|
      #       if ctx.usage_percentage > 85
      #         ctx.prune_old_messages(keep_recent: 10)
      #       else
      #         ctx.compress_tool_results(keep_recent: 5)
      #       end
      #     end
      #   end
      def context_management(&block)
        builder = ContextManagement::Builder.new
        builder.instance_eval(&block)
        @context_management_config = builder.build
      end

      # Set permissions directly from hash (for YAML translation)
      #
      # This is intentionally separate from permissions() to keep the DSL clean.
      # Called by Configuration when translating YAML permissions.
      #
      # @param hash [Hash] Permissions configuration hash
      # @return [void]
      def permissions_hash=(hash)
        @permissions_config = hash || {}
      end

      # Check if model has been explicitly set (not default)
      #
      # Used by Swarm::Builder to determine if all_agents model should apply.
      #
      # @return [Boolean] true if model was explicitly set
      def model_set?
        @model != "gpt-5"
      end

      # Check if provider has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents provider should apply.
      #
      # @return [Boolean] true if provider was explicitly set
      def provider_set?
        !@provider.nil?
      end

      # Check if base_url has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents base_url should apply.
      #
      # @return [Boolean] true if base_url was explicitly set
      def base_url_set?
        !@base_url.nil?
      end

      # Check if api_version has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents api_version should apply.
      #
      # @return [Boolean] true if api_version was explicitly set
      def api_version_set?
        !@api_version.nil?
      end

      # Check if timeout has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents timeout should apply.
      #
      # @return [Boolean] true if timeout was explicitly set
      def timeout_set?
        !@timeout.nil?
      end

      # Check if coding_agent has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents coding_agent should apply.
      #
      # @return [Boolean] true if coding_agent was explicitly set
      def coding_agent_set?
        !@coding_agent.nil?
      end

      # Check if parameters have been set
      #
      # Used by Swarm::Builder for merging all_agents parameters.
      #
      # @return [Boolean] true if parameters were set
      def parameters_set?
        @parameters.any?
      end

      # Check if headers have been set
      #
      # Used by Swarm::Builder for merging all_agents headers.
      #
      # @return [Boolean] true if headers were set
      def headers_set?
        @headers.any?
      end

      # Build and return an Agent::Definition
      #
      # This method converts the builder's configuration into a validated
      # Agent::Definition object. The caller is responsible for adding it to a swarm.
      #
      # Converts @tools Set to Array here because Agent::Definition expects an array.
      # The Set was only used during building to handle duplicates efficiently.
      #
      # @return [Agent::Definition] Fully configured and validated agent definition
      def to_definition
        agent_config = {
          description: @description || "Agent #{@name}",
          model: @model,
          system_prompt: @system_prompt,
          tools: @tools.to_a, # Convert Set to Array for Agent::Definition compatibility
          delegates_to: @delegates_to,
          directory: @directory,
        }

        # Add optional fields
        agent_config[:provider] = @provider if @provider
        agent_config[:base_url] = @base_url if @base_url
        agent_config[:api_version] = @api_version if @api_version
        agent_config[:context_window] = @context_window if @context_window
        agent_config[:parameters] = @parameters if @parameters.any?
        agent_config[:headers] = @headers if @headers.any?
        agent_config[:timeout] = @timeout if @timeout
        agent_config[:mcp_servers] = @mcp_servers if @mcp_servers.any?
        agent_config[:disable_default_tools] = @disable_default_tools unless @disable_default_tools.nil?
        agent_config[:bypass_permissions] = @bypass_permissions
        agent_config[:coding_agent] = @coding_agent
        agent_config[:assume_model_exists] = @assume_model_exists unless @assume_model_exists.nil?
        agent_config[:permissions] = @permissions_config if @permissions_config.any?
        agent_config[:default_permissions] = @default_permissions if @default_permissions.any?
        agent_config[:memory] = @memory_config if @memory_config
        agent_config[:shared_across_delegations] = @shared_across_delegations unless @shared_across_delegations.nil?

        # Convert DSL hooks to HookDefinition format
        agent_config[:hooks] = convert_hooks_to_definitions if @hooks.any?

        # Merge context management hooks into agent hooks
        if @context_management_config
          agent_config[:hooks] ||= {}
          agent_config[:hooks][:context_warning] ||= []
          agent_config[:hooks][:context_warning].concat(@context_management_config)
        end

        Agent::Definition.new(@name, agent_config)
      end

      private

      # Convert DSL hooks to HookDefinition objects for Agent::Definition
      #
      # This converts the builder's hook configuration (Ruby blocks and shell commands)
      # into HookDefinition objects that will be applied during agent initialization.
      #
      # @return [Hash] Hooks grouped by event type { event: [HookDefinition, ...] }
      def convert_hooks_to_definitions
        result = Hash.new { |h, k| h[k] = [] }

        @hooks.each do |hook_config|
          event = hook_config[:event]

          # Create HookDefinition with proc or command
          if hook_config[:block]
            # Ruby block hook
            hook_def = Hooks::Definition.new(
              event: event,
              matcher: hook_config[:matcher],
              priority: 0,
              proc: hook_config[:block],
            )
          elsif hook_config[:command]
            # Shell command hook - wrap in a block that calls ShellExecutor
            hook_def = Hooks::Definition.new(
              event: event,
              matcher: hook_config[:matcher],
              priority: 0,
              proc: create_shell_hook_proc(hook_config),
            )
          else
            raise ConfigurationError, "Hook must have either :block or :command"
          end

          result[event] << hook_def
        end

        result
      end

      # Create a proc that executes a shell command hook
      def create_shell_hook_proc(config)
        command = config[:command]
        timeout = config[:timeout] || 60
        agent_name = @name

        proc do |context|
          input_json = build_hook_input(context, config[:event])
          Hooks::ShellExecutor.execute(
            command: command,
            input_json: input_json,
            timeout: timeout,
            agent_name: agent_name,
            swarm_name: context.swarm&.name,
            event: config[:event],
          )
        end
      end

      # Build hook input JSON for shell command hooks
      def build_hook_input(context, event)
        base = { event: event.to_s, agent: @name.to_s }

        case event
        when :pre_tool_use
          base.merge(tool: context.tool_call.name, parameters: context.tool_call.parameters)
        when :post_tool_use
          base.merge(result: context.tool_result.content, success: context.tool_result.success?)
        when :user_prompt
          base.merge(prompt: context.metadata[:prompt])
        else
          base
        end
      end
    end
  end
end
