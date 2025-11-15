# frozen_string_literal: true

module SwarmSDK
  module Agent
    # Builds system prompts for agents
    #
    # This class encapsulates all system prompt construction logic, including:
    # - Base system prompt rendering (for coding agents)
    # - Non-coding base prompt rendering
    # - Plugin prompt contribution collection
    # - Combining base and custom prompts
    #
    # ## Safety Note for SwarmMemory Integration
    #
    # This is an INTERNAL helper that receives Definition attributes as input.
    # Definition remains the single source of truth with all instance variables.
    # SwarmMemory uses `agent_definition.instance_eval { binding }` for ERB templating,
    # which requires all properties to be on Definition object. This helper is safe
    # because it doesn't affect Definition's structure - it only extracts logic.
    class SystemPromptBuilder
      BASE_SYSTEM_PROMPT_PATH = File.expand_path("../prompts/base_system_prompt.md.erb", __dir__)

      class << self
        # Build the complete system prompt for an agent
        #
        # @param custom_prompt [String, nil] Custom system prompt from configuration
        # @param coding_agent [Boolean] Whether agent is configured for coding tasks
        # @param disable_default_tools [Boolean, Array, nil] Default tools disable configuration
        # @param directory [String] Agent's working directory
        # @param definition [Definition] Full definition for plugin contributions
        # @return [String] Complete system prompt
        def build(custom_prompt:, coding_agent:, disable_default_tools:, directory:, definition:)
          new(
            custom_prompt: custom_prompt,
            coding_agent: coding_agent,
            disable_default_tools: disable_default_tools,
            directory: directory,
            definition: definition,
          ).build
        end
      end

      def initialize(custom_prompt:, coding_agent:, disable_default_tools:, directory:, definition:)
        @custom_prompt = custom_prompt
        @coding_agent = coding_agent
        @disable_default_tools = disable_default_tools
        @directory = directory
        @definition = definition
      end

      def build
        prompt = base_prompt_section
        prompt = append_plugin_contributions(prompt)
        prompt
      end

      private

      def base_prompt_section
        if @coding_agent
          build_coding_agent_prompt
        elsif default_tools_enabled?
          build_non_coding_agent_prompt
        else
          (@custom_prompt || "").to_s
        end
      end

      def build_coding_agent_prompt
        rendered_base = render_base_system_prompt

        if @custom_prompt && !@custom_prompt.strip.empty?
          "#{rendered_base}\n\n#{@custom_prompt}"
        else
          rendered_base
        end
      end

      def build_non_coding_agent_prompt
        non_coding_base = render_non_coding_base_prompt

        if @custom_prompt && !@custom_prompt.strip.empty?
          "#{non_coding_base}\n\n#{@custom_prompt}"
        else
          non_coding_base
        end
      end

      def default_tools_enabled?
        @disable_default_tools != true
      end

      def render_base_system_prompt
        cwd = @directory || Dir.pwd
        platform = RUBY_PLATFORM
        os_version = begin
          %x(uname -sr 2>/dev/null).strip
        rescue
          RUBY_PLATFORM
        end
        date = Time.now.strftime("%Y-%m-%d")

        template_content = File.read(BASE_SYSTEM_PROMPT_PATH)
        ERB.new(template_content).result(binding)
      end

      def render_non_coding_base_prompt
        cwd = @directory || Dir.pwd
        platform = RUBY_PLATFORM
        os_version = begin
          %x(uname -sr 2>/dev/null).strip
        rescue
          RUBY_PLATFORM
        end
        date = Time.now.strftime("%Y-%m-%d")

        <<~PROMPT.strip
          # Today's date

          <today-date>
          #{date}
          #</today-date>

          # Current Environment

          <env>
          Working directory: #{cwd}
          Platform: #{platform}
          OS Version: #{os_version}
          </env>
        PROMPT
      end

      def append_plugin_contributions(prompt)
        contributions = collect_plugin_prompt_contributions
        return prompt if contributions.empty?

        combined_contributions = contributions.join("\n\n")

        if prompt && !prompt.strip.empty?
          "#{prompt}\n\n#{combined_contributions}"
        else
          combined_contributions
        end
      end

      def collect_plugin_prompt_contributions
        contributions = []

        PluginRegistry.all.each do |plugin|
          next unless plugin.storage_enabled?(@definition)

          contribution = plugin.system_prompt_contribution(agent_definition: @definition, storage: nil)
          contributions << contribution if contribution && !contribution.strip.empty?
        end

        contributions
      end
    end
  end
end
