# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # AllAgentsBuilder for configuring settings that apply to all agents
    #
    # Settings configured here are applied to ALL agents, but can be overridden
    # at the agent level. This is useful for shared configuration like:
    # - Common provider/base_url (all agents use same proxy)
    # - Shared timeout settings
    # - Global permissions
    #
    # @example
    #   all_agents do
    #     provider :openai
    #     base_url "http://proxy.com/v1"
    #     timeout 180
    #     tools :Read, :Write
    #     coding_agent false
    #   end
    class AllAgentsBuilder
      attr_reader :hooks, :permissions_config, :tools_list

      def initialize
        @tools_list = []
        @hooks = []
        @permissions_config = {}
        @model = nil
        @provider = nil
        @base_url = nil
        @api_version = nil
        @request_timeout = nil
        @turn_timeout = nil
        @parameters = nil
        @headers = nil
        @coding_agent = nil
        @disable_default_tools = nil
        @streaming = nil
        @thinking = nil
      end

      # Set model for all agents
      def model(model_name)
        @model = model_name
      end

      # Set provider for all agents
      def provider(provider_name)
        @provider = provider_name
      end

      # Set base URL for all agents
      def base_url(url)
        @base_url = url
      end

      # Set API version for all agents
      def api_version(version)
        @api_version = version
      end

      # Set request timeout for all agents
      def request_timeout(seconds)
        @request_timeout = seconds
      end

      # Set turn timeout for all agents
      def turn_timeout(seconds)
        @turn_timeout = seconds
      end

      # Set parameters for all agents
      def parameters(params)
        @parameters = params
      end

      # Set headers for all agents
      def headers(header_hash)
        @headers = header_hash
      end

      # Set coding_agent flag for all agents
      def coding_agent(enabled)
        @coding_agent = enabled
      end

      # Disable default tools for all agents
      #
      # @param value [Boolean, Array<Symbol>]
      #   - true: Disable ALL default tools
      #   - Array of symbols: Disable specific tools (e.g., [:Think, :TodoWrite])
      def disable_default_tools(value)
        @disable_default_tools = value
      end

      # Enable or disable streaming for all agents
      #
      # @param value [Boolean] If true, enables streaming; if false, disables it
      def streaming(value)
        @streaming = value
      end

      # Configure extended thinking for all agents
      #
      # @param effort [Symbol, String, nil] Reasoning effort (:low, :medium, :high) — OpenAI
      # @param budget [Integer, nil] Token budget for thinking — Anthropic
      def thinking(effort: nil, budget: nil)
        raise ArgumentError, "thinking requires :effort or :budget" if effort.nil? && budget.nil?

        @thinking = { effort: effort, budget: budget }.compact
      end

      # Add tools that all agents will have
      def tools(*tool_names)
        @tools_list.concat(tool_names)
      end

      # Add hook for all agents (agent-level events only)
      #
      # @example
      #   hook :pre_tool_use, matcher: "Write" do |ctx|
      #     # Applies to all agents
      #   end
      def hook(event, matcher: nil, command: nil, timeout: nil, &block)
        # Validate agent-level events
        agent_events = [
          :pre_tool_use,
          :post_tool_use,
          :user_prompt,
          :agent_step,
          :agent_stop,
          :first_message,
          :pre_delegation,
          :post_delegation,
          :context_warning,
        ]

        unless agent_events.include?(event)
          raise ArgumentError, "Invalid all_agents hook: #{event}. Swarm-level events (:swarm_start, :swarm_stop) cannot be used in all_agents block."
        end

        @hooks << { event: event, matcher: matcher, command: command, timeout: timeout, block: block }
      end

      # Configure permissions for all agents
      #
      # Supports two forms:
      # 1. Block form (DSL): permissions do ... end
      # 2. Direct hash (internal/YAML): set_permissions_hash(hash)
      #
      # @example Block form
      #   permissions do
      #     Write.allow_paths "tmp/**/*"
      #     Write.deny_paths "tmp/secrets/**"
      #     Bash.allow_commands "^git status$"
      #   end
      def permissions(&block)
        @permissions_config = PermissionsBuilder.build(&block)
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

      # Convert to hash for merging with agent configs
      #
      # @return [Hash] Configuration hash
      def to_h
        {
          model: @model,
          provider: @provider,
          base_url: @base_url,
          api_version: @api_version,
          request_timeout: @request_timeout,
          turn_timeout: @turn_timeout,
          parameters: @parameters,
          headers: @headers,
          coding_agent: @coding_agent,
          disable_default_tools: @disable_default_tools,
          streaming: @streaming,
          thinking: @thinking,
          tools: @tools_list,
          permissions: @permissions_config,
        }.compact
      end
    end
  end
end
