# frozen_string_literal: true

module SwarmSDK
  module Builders
    # Base builder with shared DSL methods for Swarm and Workflow builders
    #
    # Provides common functionality:
    # - Basic configuration (name, id, scratchpad)
    # - Agent definition (inline DSL, markdown files, with overrides)
    # - All agents configuration
    # - External swarms registry
    # - Validation helpers
    # - Merging logic
    #
    # Subclasses must implement:
    # - build_swarm - Build and return the appropriate instance
    # - Type-specific DSL methods (lead for Swarm, node/start_node for Workflow)
    #
    class BaseBuilder
      def initialize(allow_filesystem_tools: nil)
        @swarm_id = nil
        @swarm_name = nil
        @agents = {}
        @all_agents_config = nil
        @swarm_registry_config = []
        @scratchpad = :disabled
        @allow_filesystem_tools = allow_filesystem_tools
      end

      # Set swarm ID
      #
      # @param swarm_id [String] Unique identifier for this swarm/workflow
      def id(swarm_id)
        @swarm_id = swarm_id
      end

      # Set swarm/workflow name
      def name(swarm_name)
        @swarm_name = swarm_name
      end

      # Configure scratchpad mode
      #
      # For Workflow: :enabled (shared across nodes), :per_node (isolated), or :disabled
      # For Swarm: :enabled or :disabled
      #
      # @param mode [Symbol, Boolean] Scratchpad mode
      def scratchpad(mode)
        @scratchpad = mode
      end

      # Register external swarms for composable swarms
      #
      # @example
      #   swarms do
      #     register "code_review", file: "./swarms/code_review.rb"
      #     register "testing", file: "./swarms/testing.yml", keep_context: false
      #   end
      #
      # @yield Block containing register() calls
      def swarms(&block)
        builder = Swarm::SwarmRegistryBuilder.new
        builder.instance_eval(&block)
        @swarm_registry_config = builder.registrations
      end

      # Define an agent with fluent API, load from markdown, or reference registry
      #
      # Supports multiple forms:
      # 1. Registry lookup: agent :name (pulls from global registry)
      # 2. Registry + overrides: agent :name do ... end (when registered)
      # 3. Inline DSL: agent :name do ... end (when not registered)
      # 4. Markdown content: agent :name, <<~MD ... MD
      # 5. Markdown + overrides: agent :name, <<~MD do ... end
      #
      # @example Inline DSL
      #   agent :backend do
      #     model "gpt-5"
      #     system_prompt "You build APIs"
      #     tools :Read, :Write
      #   end
      #
      # @example Registry lookup (agent must be registered with SwarmSDK.agent)
      #   agent :backend  # Pulls configuration from registry
      #
      # @example Registry + overrides
      #   agent :backend do
      #     # Base config from registry, then apply overrides
      #     tools :CustomTool  # Adds to registry-defined tools
      #   end
      #
      # @example Markdown content
      #   agent :backend, <<~MD
      #     ---
      #     description: "Backend developer"
      #     model: "gpt-4"
      #     ---
      #
      #     You build APIs.
      #   MD
      def agent(name, content = nil, &block)
        name = name.to_sym

        # Case 1: agent :name, <<~MD do ... end (markdown + overrides)
        if content.is_a?(String) && block_given? && markdown_content?(content)
          load_agent_from_markdown_with_overrides(content, name, &block)

        # Case 2: agent :name, <<~MD (markdown only)
        elsif content.is_a?(String) && !block_given? && markdown_content?(content)
          load_agent_from_markdown(content, name)

        # Case 3: agent :name (registry lookup only - no content, no block)
        elsif content.nil? && !block_given?
          load_agent_from_registry(name)

        # Case 4: agent :name do ... end (with registered agent - registry + overrides)
        elsif content.nil? && block_given? && AgentRegistry.registered?(name)
          load_agent_from_registry_with_overrides(name, &block)

        # Case 5: agent :name do ... end (inline DSL - not registered)
        elsif block_given?
          builder = Agent::Builder.new(name)
          builder.instance_eval(&block)
          @agents[name] = builder

        else
          raise ArgumentError,
            "Invalid agent definition for '#{name}'. Use:\n  " \
              "agent :#{name} { ... }           # Inline DSL\n  " \
              "agent :#{name}                   # Registry lookup\n  " \
              "agent :#{name} { ... }           # Registry + overrides (if registered)\n  " \
              "agent :#{name}, <<~MD ... MD     # Markdown\n  " \
              "agent :#{name}, <<~MD do ... end # Markdown + overrides"
        end
      end

      # Configure all agents with a block
      #
      # @example
      #   all_agents do
      #     tools :Read, :Write
      #
      #     hook :pre_tool_use, matcher: "Write" do |ctx|
      #       # Validation for all agents
      #     end
      #   end
      def all_agents(&block)
        builder = Swarm::AllAgentsBuilder.new
        builder.instance_eval(&block)
        @all_agents_config = builder
      end

      # Build the actual Swarm or Workflow instance
      #
      # Subclasses must implement this method.
      #
      # @return [Swarm, Workflow] Configured instance
      def build_swarm
        raise NotImplementedError, "#{self.class} must implement #build_swarm"
      end

      protected

      # Check if a string is markdown content (has frontmatter)
      #
      # @param str [String] String to check
      # @return [Boolean] true if string contains markdown frontmatter
      def markdown_content?(str)
        str.start_with?("---") || str.include?("\n---\n")
      end

      # Load an agent from the global registry
      #
      # Retrieves the registered agent block and executes it in the context
      # of a new Agent::Builder.
      #
      # @param name [Symbol] Agent name
      # @return [void]
      # @raise [ConfigurationError] If agent is not registered
      #
      # @example
      #   load_agent_from_registry(:backend)
      def load_agent_from_registry(name)
        registered_proc = AgentRegistry.get(name)
        unless registered_proc
          raise ConfigurationError,
            "Agent '#{name}' not found in registry. " \
              "Either define inline with `agent :#{name} do ... end` or " \
              "register globally with `SwarmSDK.agent :#{name} do ... end`"
        end

        builder = Agent::Builder.new(name)
        builder.instance_eval(&registered_proc)
        @agents[name] = builder
      end

      # Load an agent from the registry with additional overrides
      #
      # Applies the registered configuration first, then executes the
      # override block to customize the agent.
      #
      # @param name [Symbol] Agent name
      # @yield Override block with additional configuration
      # @return [void]
      #
      # @example
      #   load_agent_from_registry_with_overrides(:backend) do
      #     tools :CustomTool  # Adds to registry-defined tools
      #   end
      def load_agent_from_registry_with_overrides(name, &override_block)
        registered_proc = AgentRegistry.get(name)
        # Guaranteed to exist since we checked in the condition

        builder = Agent::Builder.new(name)
        builder.instance_eval(&registered_proc)  # Base config from registry
        builder.instance_eval(&override_block)   # Apply overrides
        @agents[name] = builder
      end

      # Load an agent from markdown content
      #
      # Returns a hash of the agent config (not a Definition yet) so that
      # all_agents config can be applied later in the build process.
      #
      # @param content [String] Markdown content with frontmatter
      # @param name_override [Symbol, nil] Optional name to override frontmatter name
      # @return [void]
      def load_agent_from_markdown(content, name_override = nil)
        definition = MarkdownParser.parse(content, name_override)
        @agents[definition.name] = { __file_config__: definition.to_h }
      end

      # Load an agent from markdown content with DSL overrides
      #
      # @param content [String] Markdown content with frontmatter
      # @param name_override [Symbol, nil] Optional name to override frontmatter name
      # @yield Block with DSL overrides
      # @return [void]
      def load_agent_from_markdown_with_overrides(content, name_override = nil, &block)
        definition = MarkdownParser.parse(content, name_override)

        builder = Agent::Builder.new(definition.name)
        apply_definition_to_builder(builder, definition.to_h)
        builder.instance_eval(&block)

        @agents[definition.name] = builder
      end

      # Apply agent definition hash to a builder
      #
      # @param builder [Agent::Builder] Builder to configure
      # @param config [Hash] Configuration hash from definition
      # @return [void]
      def apply_definition_to_builder(builder, config)
        builder.description(config[:description]) if config[:description]
        builder.model(config[:model]) if config[:model]
        builder.provider(config[:provider]) if config[:provider]
        builder.base_url(config[:base_url]) if config[:base_url]
        builder.api_version(config[:api_version]) if config[:api_version]
        builder.context_window(config[:context_window]) if config[:context_window]
        builder.system_prompt(config[:system_prompt]) if config[:system_prompt]
        builder.directory(config[:directory]) if config[:directory]
        builder.timeout(config[:timeout]) if config[:timeout]
        builder.parameters(config[:parameters]) if config[:parameters]
        builder.headers(config[:headers]) if config[:headers]
        builder.coding_agent(config[:coding_agent]) unless config[:coding_agent].nil?
        builder.bypass_permissions(config[:bypass_permissions]) if config[:bypass_permissions]
        builder.disable_default_tools(config[:disable_default_tools]) unless config[:disable_default_tools].nil?

        # Add tools from markdown
        if config[:tools]&.any?
          tool_names = config[:tools].map do |tool|
            tool.is_a?(Hash) ? tool[:name] : tool
          end
          builder.tools(*tool_names)
        end

        # Add delegates_to
        builder.delegates_to(*config[:delegates_to]) if config[:delegates_to]&.any?

        # Add MCP servers
        config[:mcp_servers]&.each do |server|
          builder.mcp_server(server[:name], **server.except(:name))
        end
      end

      # Merge all_agents configuration into each agent
      #
      # All_agents values are used as defaults - agent-specific values override.
      # This applies to both inline DSL agents (Builder) and file-loaded agents (config hash).
      #
      # @return [void]
      def merge_all_agents_config_into_agents
        return unless @all_agents_config

        all_agents_hash = @all_agents_config.to_h

        @agents.each_value do |agent_builder_or_config|
          if agent_builder_or_config.is_a?(Hash) && agent_builder_or_config.key?(:__file_config__)
            # File-loaded agent - merge into the config hash
            file_config = agent_builder_or_config[:__file_config__]
            merged_config = merge_all_agents_into_config(all_agents_hash, file_config)
            agent_builder_or_config[:__file_config__] = merged_config
          else
            # Builder object (inline DSL agent)
            agent_builder = agent_builder_or_config

            apply_all_agents_defaults(agent_builder, all_agents_hash)

            # Merge tools (prepend all_agents tools)
            all_agents_tools = @all_agents_config.tools_list
            agent_builder.prepend_tools(*all_agents_tools) if all_agents_tools.any?

            # Pass all_agents permissions as default_permissions
            if @all_agents_config.permissions_config.any?
              agent_builder.default_permissions = @all_agents_config.permissions_config
            end
          end
        end
      end

      # Merge all_agents config into file-loaded agent config
      #
      # @param all_agents_hash [Hash] All_agents configuration
      # @param file_config [Hash] File-loaded agent configuration
      # @return [Hash] Merged configuration
      def merge_all_agents_into_config(all_agents_hash, file_config)
        merged = all_agents_hash.dup

        file_config.each do |key, value|
          case key
          when :tools
            merged[:tools] = Array(merged[:tools]) + Array(value)
          when :delegates_to
            merged[:delegates_to] = Array(merged[:delegates_to]) + Array(value)
          when :parameters
            merged[:parameters] = (merged[:parameters] || {}).merge(value || {})
          when :headers
            merged[:headers] = (merged[:headers] || {}).merge(value || {})
          else
            merged[key] = value
          end
        end

        # Pass all_agents permissions as default_permissions
        if all_agents_hash[:permissions] && !merged[:default_permissions]
          merged[:default_permissions] = all_agents_hash[:permissions]
        end

        merged
      end

      # Apply all_agents defaults to an agent builder
      #
      # @param agent_builder [Agent::Builder] The agent builder to configure
      # @param all_agents_hash [Hash] All_agents configuration
      # @return [void]
      def apply_all_agents_defaults(agent_builder, all_agents_hash)
        if all_agents_hash[:model] && !agent_builder.model_set?
          agent_builder.model(all_agents_hash[:model])
        end

        if all_agents_hash[:provider] && !agent_builder.provider_set?
          agent_builder.provider(all_agents_hash[:provider])
        end

        if all_agents_hash[:base_url] && !agent_builder.base_url_set?
          agent_builder.base_url(all_agents_hash[:base_url])
        end

        if all_agents_hash[:api_version] && !agent_builder.api_version_set?
          agent_builder.api_version(all_agents_hash[:api_version])
        end

        if all_agents_hash[:timeout] && !agent_builder.timeout_set?
          agent_builder.timeout(all_agents_hash[:timeout])
        end

        if all_agents_hash[:parameters]
          merged_params = all_agents_hash[:parameters].merge(agent_builder.parameters)
          agent_builder.parameters(merged_params)
        end

        if all_agents_hash[:headers]
          merged_headers = all_agents_hash[:headers].merge(agent_builder.headers)
          agent_builder.headers(merged_headers)
        end

        if !all_agents_hash[:coding_agent].nil? && !agent_builder.coding_agent_set?
          agent_builder.coding_agent(all_agents_hash[:coding_agent])
        end
      end

      # Validate all_agents filesystem tools
      #
      # @raise [ConfigurationError] If filesystem tools are disabled and all_agents has them
      # @return [void]
      def validate_all_agents_filesystem_tools
        resolved_setting = if @allow_filesystem_tools.nil?
          SwarmSDK.config.allow_filesystem_tools
        else
          @allow_filesystem_tools
        end

        return if resolved_setting
        return unless @all_agents_config&.tools_list&.any?

        forbidden = @all_agents_config.tools_list.select do |tool|
          SwarmSDK::Swarm::ToolConfigurator::FILESYSTEM_TOOLS.include?(tool.to_sym)
        end

        return if forbidden.empty?

        raise ConfigurationError,
          "Filesystem tools are globally disabled (SwarmSDK.config.allow_filesystem_tools = false) " \
            "but all_agents configuration includes: #{forbidden.join(", ")}.\n\n" \
            "This is a system-wide security setting that cannot be overridden by swarm configuration.\n" \
            "To use filesystem tools, set SwarmSDK.config.allow_filesystem_tools = true before loading the swarm."
      end

      # Validate individual agent filesystem tools
      #
      # @raise [ConfigurationError] If filesystem tools are disabled and any agent has them
      # @return [void]
      def validate_agent_filesystem_tools
        resolved_setting = if @allow_filesystem_tools.nil?
          SwarmSDK.config.allow_filesystem_tools
        else
          @allow_filesystem_tools
        end

        return if resolved_setting

        @agents.each do |agent_name, agent_builder_or_config|
          tools_list = if agent_builder_or_config.is_a?(Hash) && agent_builder_or_config.key?(:__file_config__)
            agent_builder_or_config[:__file_config__][:tools] || []
          elsif agent_builder_or_config.is_a?(Agent::Builder)
            agent_builder_or_config.tools_list
          else
            []
          end

          tool_names = tools_list.map do |tool|
            name = tool.is_a?(Hash) ? tool[:name] : tool
            name.to_sym
          end

          forbidden = tool_names.select do |tool|
            SwarmSDK::Swarm::ToolConfigurator::FILESYSTEM_TOOLS.include?(tool)
          end

          next if forbidden.empty?

          raise ConfigurationError,
            "Filesystem tools are globally disabled (SwarmSDK.config.allow_filesystem_tools = false) " \
              "but agent '#{agent_name}' attempts to use: #{forbidden.join(", ")}.\n\n" \
              "This is a system-wide security setting that cannot be overridden by swarm configuration.\n" \
              "To use filesystem tools, set SwarmSDK.config.allow_filesystem_tools = true before loading the swarm."
        end
      end

      # Build agent definitions from builders or file configs
      #
      # Handles both Agent::Builder (inline DSL) and file configs (from files).
      # Merges all_agents config before building.
      #
      # @return [Hash<Symbol, Agent::Definition>] Agent definitions
      def build_agent_definitions
        # Merge all_agents config first
        merge_all_agents_config_into_agents if @all_agents_config

        # Build definitions
        agent_definitions = {}
        @agents.each do |agent_name, agent_builder_or_config|
          agent_definitions[agent_name] = if agent_builder_or_config.is_a?(Hash) && agent_builder_or_config.key?(:__file_config__)
            # File-loaded agent config (with all_agents merged)
            Agent::Definition.new(agent_name, agent_builder_or_config[:__file_config__])
          else
            # Builder object (from inline DSL) - convert to definition
            agent_builder_or_config.to_definition
          end
        end

        agent_definitions
      end
    end
  end
end
