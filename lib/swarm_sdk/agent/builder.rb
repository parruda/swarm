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
        @request_timeout = nil
        @turn_timeout = nil
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
        @streaming = nil # nil = not set (will use global config default)
        @thinking = nil # nil = not set (extended thinking disabled)
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

      # Set/get request timeout
      def request_timeout(seconds = :__not_provided__)
        return @request_timeout if seconds == :__not_provided__

        @request_timeout = seconds
      end

      # Set/get turn timeout
      def turn_timeout(seconds = :__not_provided__)
        return @turn_timeout if seconds == :__not_provided__

        @turn_timeout = seconds
      end

      # Add an MCP server configuration
      #
      # @param name [Symbol] Server name
      # @param type [Symbol] Transport type (:stdio, :sse, :http)
      # @param tools [Array<Symbol>, nil] Tool names to expose (nil = discover all tools)
      # @param options [Hash] Transport-specific options
      #
      # @example stdio transport with discovery
      #   mcp_server :filesystem, type: :stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]
      #
      # @example stdio transport with filtered tools (faster boot)
      #   mcp_server :codebase, type: :stdio, command: "mcp-server-codebase", tools: [:search_code, :list_files]
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
      #
      # Supports multiple formats for flexibility:
      #
      # @example Simple array (backwards compatible)
      #   delegates_to :frontend, :backend, :qa
      #
      # @example Hash with custom tool names
      #   delegates_to frontend: "AskFrontend",
      #                backend: "GetBackendHelp",
      #                qa: "RequestReview"
      #
      # @example Mixed - some auto, some custom
      #   delegates_to :frontend,
      #                backend: "GetBackendHelp",
      #                :qa
      #
      # @example With delegation options (preserve_context controls context persistence)
      #   delegates_to :frontend,
      #                { agent: :backend, tool_name: "AskBackend", preserve_context: false }
      #
      # @param agent_names_and_options [Array<Symbol, Hash>] Agent names and/or hash with custom tool names
      # @return [void]
      def delegates_to(*agent_names_and_options)
        agent_names_and_options.each do |item|
          case item
          when Symbol, String
            # Simple format: :frontend
            @delegates_to << { agent: item.to_sym, tool_name: nil, preserve_context: true }
          when Hash
            if item.key?(:agent)
              # Full config format: { agent: :backend, tool_name: "Custom", preserve_context: false }
              @delegates_to << {
                agent: item[:agent].to_sym,
                tool_name: item[:tool_name],
                preserve_context: item.fetch(:preserve_context, true),
              }
            else
              # Hash format: { frontend: "AskFrontend", backend: nil }
              item.each do |agent, tool_name|
                @delegates_to << { agent: agent.to_sym, tool_name: tool_name, preserve_context: true }
              end
            end
          else
            raise ConfigurationError, "delegates_to accepts Symbols or Hashes, got #{item.class}"
          end
        end
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

      # Enable or disable streaming for LLM API responses
      #
      # @param value [Boolean] If true (default), enables streaming; if false, disables it
      # @return [self] Returns self for method chaining
      #
      # @example Enable streaming (default)
      #   streaming true
      #
      # @example Disable streaming
      #   streaming false
      def streaming(value = true)
        @streaming = value
        self
      end

      # Check if streaming has been explicitly set
      #
      # @return [Boolean] true if streaming was explicitly set, false otherwise
      def streaming_set?
        !@streaming.nil?
      end

      # Configure extended thinking for this agent
      #
      # Extended thinking allows models to reason through complex problems before responding.
      # For Anthropic models, specify a budget (token count). For OpenAI models, specify effort.
      # Both can be specified for cross-provider compatibility.
      #
      # @param effort [Symbol, String, nil] Reasoning effort level (:low, :medium, :high) — used by OpenAI
      # @param budget [Integer, nil] Token budget for thinking — used by Anthropic
      # @return [self] Returns self for method chaining
      #
      # @example Anthropic thinking with budget
      #   thinking budget: 10_000
      #
      # @example OpenAI reasoning effort
      #   thinking effort: :high
      #
      # @example Cross-provider (both)
      #   thinking effort: :high, budget: 10_000
      def thinking(effort: nil, budget: nil)
        raise ArgumentError, "thinking requires :effort or :budget" if effort.nil? && budget.nil?

        @thinking = { effort: effort, budget: budget }.compact
        self
      end

      # Check if thinking has been explicitly set
      #
      # @return [Boolean] true if thinking was explicitly configured
      def thinking_set?
        !@thinking.nil?
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

      # Check if request_timeout has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents request_timeout should apply.
      #
      # @return [Boolean] true if request_timeout was explicitly set
      def request_timeout_set?
        !@request_timeout.nil?
      end

      # Check if turn_timeout has been explicitly set
      #
      # Used by Swarm::Builder to determine if all_agents turn_timeout should apply.
      #
      # @return [Boolean] true if turn_timeout was explicitly set
      def turn_timeout_set?
        !@turn_timeout.nil?
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
        agent_config[:request_timeout] = @request_timeout if @request_timeout
        agent_config[:turn_timeout] = @turn_timeout if @turn_timeout
        agent_config[:mcp_servers] = @mcp_servers if @mcp_servers.any?
        agent_config[:disable_default_tools] = @disable_default_tools unless @disable_default_tools.nil?
        agent_config[:bypass_permissions] = @bypass_permissions
        agent_config[:coding_agent] = @coding_agent
        agent_config[:assume_model_exists] = @assume_model_exists unless @assume_model_exists.nil?
        agent_config[:permissions] = @permissions_config if @permissions_config.any?
        agent_config[:default_permissions] = @default_permissions if @default_permissions.any?
        agent_config[:memory] = @memory_config if @memory_config
        agent_config[:shared_across_delegations] = @shared_across_delegations unless @shared_across_delegations.nil?
        agent_config[:streaming] = @streaming unless @streaming.nil?
        agent_config[:thinking] = @thinking if @thinking

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
