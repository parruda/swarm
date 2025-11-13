# frozen_string_literal: true

module SwarmSDK
  class Swarm
    # Builder provides a beautiful Ruby DSL for building swarms
    #
    # The DSL combines YAML simplicity with Ruby power, enabling:
    # - Fluent, chainable configuration
    # - Hooks as Ruby blocks OR shell commands
    # - Full Ruby language features (variables, conditionals, loops)
    # - Type-safe, IDE-friendly API
    #
    # @example Basic usage
    #   swarm = SwarmSDK.build do
    #     name "Dev Team"
    #     lead :backend
    #
    #     agent :backend do
    #       model "gpt-5"
    #       prompt "You build APIs"
    #       tools :Read, :Write, :Bash
    #
    #       # Hook as Ruby block - inline logic!
    #       hook :pre_tool_use, matcher: "Bash" do |ctx|
    #         SwarmSDK::Hooks::Result.halt("Blocked!") if ctx.tool_call.parameters[:command].include?("rm -rf")
    #       end
    #     end
    #   end
    #
    #   swarm.execute("Build auth API")
    class Builder < Builders::BaseBuilder
      # Main entry point for DSL
      #
      # @example
      #   swarm = SwarmSDK.build do
      #     name "Team"
      #     agent :backend { ... }
      #   end
      class << self
        def build(allow_filesystem_tools: nil, &block)
          builder = new(allow_filesystem_tools: allow_filesystem_tools)
          builder.instance_eval(&block)
          builder.build_swarm
        end
      end

      def initialize(allow_filesystem_tools: nil)
        super
        @lead_agent = nil
        @swarm_hooks = []
      end

      # Set lead agent
      def lead(agent_name)
        @lead_agent = agent_name
      end

      # Add swarm-level hook (swarm_start, swarm_stop only)
      #
      # @example Shell command
      #   hook :swarm_start, command: "echo 'Starting' >> log.txt"
      #
      # @example Ruby block
      #   hook :swarm_start do |ctx|
      #     puts "Swarm starting: #{ctx.metadata[:prompt]}"
      #   end
      def hook(event, command: nil, timeout: nil, &block)
        # Validate swarm-level events
        unless [:swarm_start, :swarm_stop].include?(event)
          raise ArgumentError, "Invalid swarm-level hook: #{event}. Only :swarm_start and :swarm_stop allowed at swarm level. Use all_agents { hook ... } or agent { hook ... } for other events."
        end

        @swarm_hooks << { event: event, command: command, timeout: timeout, block: block }
      end

      # Build the actual Swarm instance
      def build_swarm
        raise ConfigurationError, "Swarm name not set. Use: name 'My Swarm'" unless @swarm_name
        raise ConfigurationError, "No agents defined. Use: agent :name { ... }" if @agents.empty?
        raise ConfigurationError, "Lead agent not set. Use: lead :agent_name" unless @lead_agent

        # Validate filesystem tools BEFORE building
        validate_all_agents_filesystem_tools if @all_agents_config
        validate_agent_filesystem_tools

        build_single_swarm
      end

      private

      # Build a traditional single-swarm execution
      #
      # @return [Swarm] Configured swarm instance
      def build_single_swarm
        # Validate swarm_id is set if external swarms are registered (required for composable swarms)
        if @swarm_registry_config.any? && @swarm_id.nil?
          raise ConfigurationError, "Swarm id must be set using id(...) when using composable swarms"
        end

        # Create swarm using SDK (swarm_id auto-generates if nil)
        swarm = Swarm.new(
          name: @swarm_name,
          swarm_id: @swarm_id,
          scratchpad_mode: @scratchpad,
          allow_filesystem_tools: @allow_filesystem_tools,
        )

        # Setup swarm registry if external swarms are registered
        if @swarm_registry_config.any?
          registry = SwarmRegistry.new(parent_swarm_id: @swarm_id)
          @swarm_registry_config.each do |reg|
            registry.register(reg[:name], source: reg[:source], keep_context: reg[:keep_context])
          end
          swarm.swarm_registry = registry
        end

        # Build agent definitions and add to swarm
        agent_definitions = build_agent_definitions
        agent_definitions.each_value do |definition|
          swarm.add_agent(definition)
        end

        # Set lead
        swarm.lead = @lead_agent

        # Apply swarm hooks (Ruby blocks)
        @swarm_hooks.each do |hook_config|
          apply_swarm_hook(swarm, hook_config)
        end

        # Apply all_agents hooks (Ruby blocks)
        @all_agents_config&.hooks&.each do |hook_config|
          apply_all_agents_hook(swarm, hook_config)
        end

        swarm
      end

      def apply_swarm_hook(swarm, config)
        event = config[:event]

        if config[:block]
          # Ruby block hook - register directly
          swarm.add_default_callback(event, &config[:block])
        elsif config[:command]
          # Shell command hook - use ShellExecutor
          swarm.add_default_callback(event) do |context|
            input_json = build_hook_input(context, event)
            Hooks::ShellExecutor.execute(
              command: config[:command],
              input_json: input_json,
              timeout: config[:timeout] || 60,
              swarm_name: swarm.name,
              event: event,
            )
          end
        end
      end

      def apply_all_agents_hook(swarm, config)
        event = config[:event]
        matcher = config[:matcher]

        if config[:block]
          # Ruby block hook
          swarm.add_default_callback(event, matcher: matcher, &config[:block])
        elsif config[:command]
          # Shell command hook
          swarm.add_default_callback(event, matcher: matcher) do |context|
            input_json = build_hook_input(context, event)
            Hooks::ShellExecutor.execute(
              command: config[:command],
              input_json: input_json,
              timeout: config[:timeout] || 60,
              agent_name: context.agent_name,
              swarm_name: swarm.name,
              event: event,
            )
          end
        end
      end

      def build_hook_input(context, event)
        # Build JSON input for shell hooks
        base = { event: event.to_s }

        case event
        when :pre_tool_use
          base.merge(tool: context.tool_call.name, parameters: context.tool_call.parameters)
        when :post_tool_use
          base.merge(result: context.tool_result.content, success: context.tool_result.success?)
        when :user_prompt
          base.merge(prompt: context.metadata[:prompt])
        when :swarm_start
          base.merge(prompt: context.metadata[:prompt])
        when :swarm_stop
          base.merge(success: context.metadata[:success], duration: context.metadata[:duration])
        else
          base
        end
      end
    end

    # Helper class for swarms block in DSL (kept in this file for reference)
    # Actual implementation is in swarm_registry_builder.rb for Zeitwerk
  end
end
