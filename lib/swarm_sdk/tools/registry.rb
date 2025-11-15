# frozen_string_literal: true

module SwarmSDK
  module Tools
    # Registry for built-in SwarmSDK tools
    #
    # Maps tool names (symbols) to their RubyLLM::Tool classes.
    # Provides validation, lookup, and factory functionality for tool registration.
    #
    # ## Tool Creation Pattern
    #
    # Tools register themselves with their creation requirements via the `tool_factory` method.
    # This eliminates the need for a giant case statement in ToolConfigurator.
    #
    # Tools fall into three categories:
    # 1. **No params**: Simple tools with no initialization requirements (Think, Clock)
    # 2. **Directory only**: Tools needing working directory (Bash, Grep, Glob)
    # 3. **Agent context**: Tools needing agent tracking (Read, Write, Edit, MultiEdit)
    # 4. **Scratchpad**: Tools needing scratchpad storage instance
    #
    # @example Adding a new tool with creation requirements
    #   # In the tool class:
    #   class MyTool < RubyLLM::Tool
    #     def self.creation_requirements
    #       [:agent_name, :directory]
    #     end
    #   end
    #
    #   # In registry:
    #   BUILTIN_TOOLS = {
    #     MyTool: SwarmSDK::Tools::MyTool,
    #   }
    #
    # Note: Plugin-provided tools (e.g., memory tools) are NOT in this registry.
    # They are registered via SwarmSDK::PluginRegistry instead.
    class Registry
      # All available built-in tools
      #
      # Maps tool names to their classes. The class must respond to `creation_requirements`
      # to specify what parameters are needed for instantiation.
      BUILTIN_TOOLS = {
        Read: SwarmSDK::Tools::Read,
        Write: SwarmSDK::Tools::Write,
        Edit: SwarmSDK::Tools::Edit,
        MultiEdit: SwarmSDK::Tools::MultiEdit,
        Bash: SwarmSDK::Tools::Bash,
        Grep: SwarmSDK::Tools::Grep,
        Glob: SwarmSDK::Tools::Glob,
        TodoWrite: SwarmSDK::Tools::TodoWrite,
        ScratchpadWrite: :scratchpad, # Requires scratchpad storage instance
        ScratchpadRead: :scratchpad,  # Requires scratchpad storage instance
        ScratchpadList: :scratchpad,  # Requires scratchpad storage instance
        Think: SwarmSDK::Tools::Think,
        WebFetch: SwarmSDK::Tools::WebFetch,
        Clock: SwarmSDK::Tools::Clock,
      }.freeze

      class << self
        # Get tool class by name
        #
        # Note: Plugin-provided tools are NOT returned by this method.
        # They are managed by SwarmSDK::PluginRegistry instead.
        #
        # @param name [Symbol, String] Tool name
        # @return [Class, Symbol, nil] Tool class, :scratchpad marker, or nil if not found
        def get(name)
          name_sym = name.to_sym
          BUILTIN_TOOLS[name_sym]
        end

        # Create a tool instance using the Factory Pattern
        #
        # Uses the tool's `creation_requirements` class method to determine
        # what parameters to pass to the constructor.
        #
        # @param name [Symbol, String] Tool name
        # @param context [Hash] Available context for tool creation
        # @option context [Symbol] :agent_name Agent identifier
        # @option context [String] :directory Agent's working directory
        # @option context [Object] :scratchpad_storage Scratchpad storage instance
        # @return [RubyLLM::Tool] Instantiated tool
        # @raise [ConfigurationError] If tool is unknown or has unmet requirements
        def create(name, context = {})
          name_sym = name.to_sym
          tool_entry = BUILTIN_TOOLS[name_sym]

          raise ConfigurationError, "Unknown tool: #{name}" unless tool_entry

          # Handle scratchpad tools specially (they use factory methods)
          if tool_entry == :scratchpad
            return create_scratchpad_tool(name_sym, context[:scratchpad_storage])
          end

          # Get the tool class and its requirements
          tool_class = tool_entry

          # Check if tool defines creation requirements
          if tool_class.respond_to?(:creation_requirements)
            requirements = tool_class.creation_requirements
            params = extract_params(requirements, context, name)
            tool_class.new(**params)
          else
            # No requirements - simple instantiation
            tool_class.new
          end
        end

        # Get multiple tool classes by names
        #
        # @param names [Array<Symbol, String>] Tool names
        # @return [Array<Class>] Array of tool classes
        # @raise [ConfigurationError] If any tool name is invalid
        def get_many(names)
          names.map do |name|
            tool_class = get(name)
            unless tool_class
              raise ConfigurationError,
                "Unknown tool: #{name}. Available tools: #{available_names.join(", ")}"
            end

            tool_class
          end
        end

        # Check if a tool exists
        #
        # Note: Only checks built-in tools. Plugin-provided tools are checked
        # via SwarmSDK::PluginRegistry.plugin_tool?() instead.
        #
        # @param name [Symbol, String] Tool name
        # @return [Boolean]
        def exists?(name)
          name_sym = name.to_sym
          BUILTIN_TOOLS.key?(name_sym)
        end

        # Get all available built-in tool names
        #
        # Note: Does NOT include plugin-provided tools. To get all available tools
        # including plugins, combine with SwarmSDK::PluginRegistry.tools.
        #
        # @return [Array<Symbol>]
        def available_names
          BUILTIN_TOOLS.keys
        end

        # Validate tool names
        #
        # @param names [Array<Symbol, String>] Tool names to validate
        # @return [Array<Symbol>] Invalid tool names
        def validate(names)
          names.reject { |name| exists?(name) }
        end

        private

        # Extract required parameters from context
        #
        # @param requirements [Array<Symbol>] Required parameter names
        # @param context [Hash] Available context
        # @param tool_name [Symbol] Tool name for error messages
        # @return [Hash] Parameters to pass to tool constructor
        # @raise [ConfigurationError] If required parameter is missing
        def extract_params(requirements, context, tool_name)
          params = {}

          requirements.each do |req|
            unless context.key?(req)
              raise ConfigurationError,
                "Tool #{tool_name} requires #{req} but it was not provided in context"
            end

            params[req] = context[req]
          end

          params
        end

        # Create a scratchpad tool using its factory method
        #
        # @param name [Symbol] Scratchpad tool name
        # @param storage [Object] Scratchpad storage instance
        # @return [RubyLLM::Tool] Instantiated scratchpad tool
        # @raise [ConfigurationError] If storage is not provided
        def create_scratchpad_tool(name, storage)
          unless storage
            raise ConfigurationError,
              "Scratchpad tool #{name} requires scratchpad_storage in context"
          end

          case name
          when :ScratchpadWrite
            Tools::Scratchpad::ScratchpadWrite.create_for_scratchpad(storage)
          when :ScratchpadRead
            Tools::Scratchpad::ScratchpadRead.create_for_scratchpad(storage)
          when :ScratchpadList
            Tools::Scratchpad::ScratchpadList.create_for_scratchpad(storage)
          else
            raise ConfigurationError, "Unknown scratchpad tool: #{name}"
          end
        end
      end
    end
  end
end
