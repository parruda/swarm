# frozen_string_literal: true

module ClaudeSwarm
  class ClaudeMcpServer
    # Class variables to share state with tool classes
    class << self
      attr_accessor :executor, :instance_config, :logger, :session_path, :calling_instance, :calling_instance_id
    end

    def initialize(instance_config, calling_instance:, calling_instance_id: nil, debug: false)
      @instance_config = instance_config
      @calling_instance = calling_instance
      @calling_instance_id = calling_instance_id

      # Create appropriate executor based on provider
      common_params = {
        working_directory: instance_config[:directory],
        model: instance_config[:model],
        mcp_config: instance_config[:mcp_config_path],
        vibe: instance_config[:vibe],
        instance_name: instance_config[:name],
        instance_id: instance_config[:instance_id],
        calling_instance: calling_instance,
        calling_instance_id: calling_instance_id,
        claude_session_id: instance_config[:claude_session_id],
        additional_directories: instance_config[:directories][1..] || [],
        debug: debug,
      }

      @executor = if instance_config[:provider] == "openai"
        OpenAI::Executor.new(
          **common_params,
          # OpenAI-specific parameters
          temperature: instance_config[:temperature],
          api_version: instance_config[:api_version],
          openai_token_env: instance_config[:openai_token_env],
          base_url: instance_config[:base_url],
          reasoning_effort: instance_config[:reasoning_effort],
          zdr: instance_config[:zdr],
        )
      else
        # Default Claude behavior - always use SDK
        ClaudeCodeExecutor.new(**common_params)
      end

      # Set class variables so tools can access them
      self.class.executor = @executor
      self.class.instance_config = @instance_config
      self.class.logger = @executor.logger
      self.class.session_path = @executor.session_path
      self.class.calling_instance = @calling_instance
      self.class.calling_instance_id = @calling_instance_id
    end

    def start
      server = FastMcp::Server.new(
        name: @instance_config[:name],
        version: "1.0.0",
      )

      # Set dynamic description for TaskTool based on instance config
      thinking_info = " Thinking budget levels: \"think\" < \"think hard\" < \"think harder\" < \"ultrathink\"."
      if @instance_config[:description]
        Tools::TaskTool.description("Execute a task using Agent #{@instance_config[:name]}. #{@instance_config[:description]} #{thinking_info}")
      else
        Tools::TaskTool.description("Execute a task using Agent #{@instance_config[:name]}. #{thinking_info}")
      end

      # Register tool classes (not instances)
      server.register_tool(Tools::TaskTool)
      server.register_tool(Tools::SessionInfoTool)
      server.register_tool(Tools::ResetSessionTool)

      # Start the stdio server
      server.start
    end
  end
end
