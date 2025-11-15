# frozen_string_literal: true

module SwarmSDK
  class Configuration
    # Translates parsed configuration to Swarm/Workflow using DSL builders
    #
    # This class is responsible for:
    # - Creating the appropriate builder (Swarm::Builder or Workflow::Builder)
    # - Translating parsed configuration into DSL method calls
    # - Building the final Swarm or Workflow instance
    #
    # Receives a parsed Configuration::Parser and converts it to runtime objects.
    class Translator
      def initialize(parser)
        @parser = parser
      end

      def to_swarm(allow_filesystem_tools: nil)
        builder = create_builder(allow_filesystem_tools)

        translate_common_config(builder)
        translate_type_specific_config(builder)
        translate_agents(builder)
        translate_hooks(builder)

        builder.build_swarm
      end

      private

      def create_builder(allow_filesystem_tools)
        if @parser.config_type == :swarm
          Swarm::Builder.new(allow_filesystem_tools: allow_filesystem_tools)
        else
          Workflow::Builder.new(allow_filesystem_tools: allow_filesystem_tools)
        end
      end

      def translate_common_config(builder)
        builder.id(@parser.swarm_id) if @parser.swarm_id
        builder.name(@parser.swarm_name)
        builder.scratchpad(@parser.scratchpad_mode)

        if @parser.external_swarms&.any?
          external_swarms = @parser.external_swarms
          builder.swarms do
            external_swarms.each do |name, config|
              source = config[:source]
              case source[:type]
              when :file
                register(name, file: source[:value], keep_context: config[:keep_context])
              when :yaml
                register(name, yaml: source[:value], keep_context: config[:keep_context])
              else
                raise ConfigurationError, "Unknown source type: #{source[:type]}"
              end
            end
          end
        end

        translate_all_agents(builder) if @parser.all_agents_config.any?
      end

      def translate_type_specific_config(builder)
        if @parser.config_type == :swarm
          builder.lead(@parser.lead_agent)
        else
          builder.start_node(@parser.start_node)
          translate_nodes(builder)
        end
      end

      def translate_hooks(builder)
        return if @parser.swarm_hooks.none?

        @parser.swarm_hooks.each do |event, hook_specs|
          Array(hook_specs).each do |spec|
            if spec[:type] == "command"
              builder.hook(event, command: spec[:command], timeout: spec[:timeout])
            end
          end
        end
      end

      def translate_all_agents(builder)
        all_agents_cfg = @parser.all_agents_config
        all_agents_hks = @parser.all_agents_hooks

        builder.all_agents do
          tools(*all_agents_cfg[:tools]) if all_agents_cfg[:tools]&.any?
          model(all_agents_cfg[:model]) if all_agents_cfg[:model]
          provider(all_agents_cfg[:provider]) if all_agents_cfg[:provider]
          base_url(all_agents_cfg[:base_url]) if all_agents_cfg[:base_url]
          api_version(all_agents_cfg[:api_version]) if all_agents_cfg[:api_version]
          timeout(all_agents_cfg[:timeout]) if all_agents_cfg[:timeout]
          parameters(all_agents_cfg[:parameters]) if all_agents_cfg[:parameters]
          headers(all_agents_cfg[:headers]) if all_agents_cfg[:headers]
          coding_agent(all_agents_cfg[:coding_agent]) unless all_agents_cfg[:coding_agent].nil?
          disable_default_tools(all_agents_cfg[:disable_default_tools]) unless all_agents_cfg[:disable_default_tools].nil?

          if all_agents_hks.any?
            all_agents_hks.each do |event, hook_specs|
              Array(hook_specs).each do |spec|
                matcher = spec[:matcher]
                hook(event, matcher: matcher, command: spec[:command], timeout: spec[:timeout]) if spec[:type] == "command"
              end
            end
          end

          self.permissions_hash = all_agents_cfg[:permissions] if all_agents_cfg[:permissions]
        end
      end

      def translate_agents(builder)
        @parser.agents.each do |name, agent_config|
          translate_agent(builder, name, agent_config)
        rescue ConfigurationError => e
          raise ConfigurationError, "Error in #{@parser.config_type}.agents.#{name}: #{e.message}"
        end
      end

      def translate_agent(builder, name, config)
        if config[:agent_file]
          agent_file_path = resolve_agent_file_path(config[:agent_file])

          unless File.exist?(agent_file_path)
            raise ConfigurationError, "Agent file not found: #{agent_file_path}"
          end

          content = File.read(agent_file_path)
          overrides = config.except(:agent_file)

          if overrides.any?
            builder.agent(name, content, &create_agent_config_block(overrides))
          else
            builder.agent(name, content)
          end
        else
          builder.agent(name, &create_agent_config_block(config))
        end
      rescue StandardError => e
        raise ConfigurationError, "Error loading agent '#{name}': #{e.message}"
      end

      def create_agent_config_block(config)
        proc do
          description(config[:description]) if config[:description]
          model(config[:model]) if config[:model]
          provider(config[:provider]) if config[:provider]
          base_url(config[:base_url]) if config[:base_url]
          api_version(config[:api_version]) if config[:api_version]
          context_window(config[:context_window]) if config[:context_window]
          system_prompt(config[:system_prompt]) if config[:system_prompt]
          directory(config[:directory]) if config[:directory]
          timeout(config[:timeout]) if config[:timeout]
          parameters(config[:parameters]) if config[:parameters]
          headers(config[:headers]) if config[:headers]
          coding_agent(config[:coding_agent]) unless config[:coding_agent].nil?
          bypass_permissions(config[:bypass_permissions]) if config[:bypass_permissions]
          disable_default_tools(config[:disable_default_tools]) unless config[:disable_default_tools].nil?
          shared_across_delegations(config[:shared_across_delegations]) unless config[:shared_across_delegations].nil?

          if config[:tools]&.any?
            tool_names = config[:tools].map { |t| t.is_a?(Hash) ? t[:name] : t }
            tools(*tool_names)
          end

          delegates_to(*config[:delegates_to]) if config[:delegates_to]&.any?

          config[:mcp_servers]&.each do |server|
            mcp_server(server[:name], **server.except(:name))
          end

          config[:hooks]&.each do |event, hook_specs|
            Array(hook_specs).each do |spec|
              matcher = spec[:matcher]
              hook(event, matcher: matcher, command: spec[:command], timeout: spec[:timeout]) if spec[:type] == "command"
            end
          end

          if config[:memory]
            memory do
              directory(config[:memory][:directory]) if config[:memory][:directory]
              adapter(config[:memory][:adapter]) if config[:memory][:adapter]
              mode(config[:memory][:mode]) if config[:memory][:mode]
            end
          end

          self.permissions_hash = config[:permissions] if config[:permissions]
        end
      end

      def translate_nodes(builder)
        @parser.nodes.each do |node_name, node_config|
          builder.node(node_name) do
            node_config[:agents]&.each do |agent_config|
              agent_name = agent_config[:agent].to_sym
              delegates = agent_config[:delegates_to] || []
              reset_ctx = agent_config.key?(:reset_context) ? agent_config[:reset_context] : true
              tools_override = agent_config[:tools]

              agent_cfg = agent(agent_name, reset_context: reset_ctx)
              agent_cfg = agent_cfg.delegates_to(*delegates) if delegates.any?
              agent_cfg.tools(*tools_override) if tools_override
            end

            depends_on(*node_config[:dependencies]) if node_config[:dependencies]&.any?

            lead(node_config[:lead].to_sym) if node_config[:lead]

            if node_config[:input_command]
              input_command(node_config[:input_command], timeout: node_config[:input_timeout] || 60)
            end

            if node_config[:output_command]
              output_command(node_config[:output_command], timeout: node_config[:output_timeout] || 60)
            end
          end
        end
      end

      def resolve_agent_file_path(file_path)
        return file_path if Pathname.new(file_path).absolute?

        @parser.base_dir.join(file_path).to_s
      end
    end
  end
end
