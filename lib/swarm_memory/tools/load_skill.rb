# frozen_string_literal: true

module SwarmMemory
  module Tools
    # Tool for loading skills from memory and dynamically swapping agent tools
    #
    # LoadSkill reads a skill from memory, validates it, and swaps the agent's
    # mutable tools to match the skill's requirements. Immutable tools (Memory*,
    # Think, LoadSkill) are always preserved.
    #
    # Skills must:
    # - Be stored in the skill/ hierarchy
    # - Have type: 'skill' in metadata
    # - Include tools array in metadata (optional)
    # - Include permissions hash in metadata (optional)
    class LoadSkill < SwarmSDK::Tools::Base
      removable false # LoadSkill is always available
      description <<~DESC
        Load a skill from memory and dynamically adapt your toolset to execute it.

        REQUIRED: Provide the file_path parameter - path to the skill in memory (must start with 'skill/').

        **Parameters:**
        - file_path (REQUIRED): Path to skill in memory - MUST start with 'skill/' (e.g., 'skill/debug-react-perf', 'skill/meta/deep-learning')

        **What Happens When You Load a Skill:**

        1. **Tool Swapping**: Your mutable tools are replaced with the skill's required tools
           - Immutable tools (Memory*, LoadSkill) always remain available
           - Skill's tool list completely replaces your current mutable tools

        2. **Permissions Applied**: Tool permissions from skill metadata are applied
           - Skill permissions override agent default permissions
           - Allows/denies specific tool actions as defined in skill

        3. **Skill Content Returned**: Returns the skill's step-by-step instructions
           - Read and follow the instructions carefully

        4. **System Reminder Injected**: You'll see your complete updated toolset
           - Lists all tools now available to you
           - Only use tools from the updated list

        **Skill Requirements:**

        Skills MUST:
        - Be stored in skill/ hierarchy ONLY (skill/ is one of exactly 4 memory categories)
        - Path MUST start with 'skill/' (e.g., 'skill/debugging/api.md', 'skill/meta/deep-learning.md')
        - Have type: 'skill' in metadata
        - Optionally specify tools array in metadata
        - Optionally specify permissions hash in metadata

        **MEMORY CATEGORIES (4 Fixed Only):**
        concept/, fact/, skill/, experience/ - NO OTHER top-level categories exist

        **Skill Metadata Example:**
        ```yaml
        type: skill
        tools: [Read, Edit, Bash, Grep]
        permissions:
          Bash:
            allow_commands: ["npm", "pytest", "bundle"]
            deny_commands: ["rm", "sudo"]
        tags: [debugging, react, performance]
        ```

        **Usage Flow:**

        ```
        # 1. Find available skills (skill/ is one of 4 fixed memory categories)
        MemoryGlob(pattern: "skill/**")

        # 2. Read skill to understand it
        MemoryRead(file_path: "skill/debugging/api-errors.md")

        # 3. Load skill to adapt tools and get instructions
        LoadSkill(file_path: "skill/debugging/api-errors.md")

        # 4. Follow the skill's instructions using your updated toolset
        ```

        **Examples:**

        ```
        # Load a debugging skill
        LoadSkill(file_path: "skill/debugging/api-errors.md")

        # Load a meta-skill (skills about skills)
        LoadSkill(file_path: "skill/meta/deep-learning.md")

        # Load a testing skill
        LoadSkill(file_path: "skill/testing/unit-tests.md")
        ```

        **Important Notes:**

        - **Read Before Loading**: Use MemoryRead first to see what the skill does
        - **Tool Swap**: Loading a skill changes your available tools - be aware of this
        - **Immutable Tools**: Memory tools and LoadSkill are NEVER removed
        - **Follow Instructions**: The skill content provides step-by-step guidance
        - **One Skill at a Time**: Loading a new skill replaces the previous skill's toolset
        - **Skill Validation**: Tool will fail if path doesn't start with 'skill/' or entry isn't type: 'skill'

        **Skill Types:**

        1. **Task Skills**: Specific procedures (debugging, testing, refactoring)
        2. **Meta-Skills**: Skills about skills (deep-learning, skill-creation)
        3. **Domain Skills**: Specialized knowledge (frontend, backend, data-analysis)

        **Creating Your Own Skills:**

        Skills are just memory entries with special metadata. To create one:
        1. Write step-by-step instructions in markdown
        2. Store in skill/ hierarchy
        3. Add metadata: type='skill', tools array, optional permissions
        4. Test by loading and following instructions

        **Common Use Cases:**

        - Following established procedures consistently
        - Accessing specialized toolsets for specific tasks
        - Learning new workflows via step-by-step guidance
        - Enforcing tool restrictions for safety
        - Standardizing approaches across sessions
      DESC

      param :file_path,
        desc: "Path to skill - MUST start with 'skill/' (one of 4 fixed memory categories). Examples: 'skill/debugging/api-errors.md', 'skill/meta/deep-learning.md'",
        required: true

      # Initialize with storage and chat context
      #
      # @param storage [Core::Storage] Memory storage
      # @param agent_name [Symbol] Agent identifier
      # @param chat [SwarmSDK::Agent::Chat] The agent's chat instance
      # @param tool_configurator [SwarmSDK::ToolConfigurator] For creating tools (unused in Plan 025)
      # @param agent_definition [SwarmSDK::Agent::Definition] For permissions (unused in Plan 025)
      def initialize(storage:, agent_name:, chat:, tool_configurator: nil, agent_definition: nil)
        super()
        @storage = storage
        @agent_name = agent_name
        @chat = chat
        # NOTE: tool_configurator and agent_definition kept for API compatibility
        # but unused in Plan 025 (tools come from registry, not recreation)
      end

      # Override name to return simple "LoadSkill"
      def name
        "LoadSkill"
      end

      # Execute the tool (Plan 025: Simplified - no tool swapping)
      #
      # @param file_path [String] Path to skill in memory
      # @return [String] Skill content with line numbers, or error message
      def execute(file_path:)
        # 1. Validate path starts with skill/
        unless file_path.start_with?("skill/")
          return validation_error("Skills must be stored in skill/ hierarchy. Got: #{file_path}")
        end

        # 2. Read entry with metadata
        begin
          entry = @storage.read_entry(file_path: file_path)
        rescue ArgumentError => e
          return validation_error(e.message)
        end

        # 3. Validate it's a skill
        unless entry.metadata && entry.metadata["type"] == "skill"
          type = entry.metadata&.dig("type") || "none"
          return validation_error("memory://#{file_path} is not a skill (type: #{type})")
        end

        # 4. Extract tool requirements and permissions
        required_tools = entry.metadata["tools"]
        permissions = entry.metadata["permissions"] || {}

        # 5. Validate tools exist in registry (only if tools are specified and non-empty)
        if required_tools && !required_tools.empty?
          begin
            validate_skill_tools(required_tools)
          rescue ArgumentError => e
            return validation_error(e.message)
          end
        end

        # 6. Create and set skill state
        # Note: tools: nil or tools: [] both mean "no restriction" (keep all tools)
        skill_state = SwarmMemory::SkillState.new(
          file_path: file_path,
          tools: required_tools, # May be nil or [] (no restriction)
          permissions: permissions,
        )
        @chat.load_skill_state(skill_state)

        # 7. Activate tools if skill restricts them
        # If no restriction (nil or []), tools remain unchanged
        if skill_state.restricts_tools?
          @chat.activate_tools_for_prompt
        end
        # Otherwise, tools stay as-is (no swap)

        # 8. Return content with confirmation message
        title = entry.title || "Untitled Skill"
        result = "Loaded skill: #{title}\n\n"
        result += entry.content

        # 9. Add system reminder if tools were restricted
        if skill_state.restricts_tools?
          result += "\n\n"
          result += build_toolset_update_reminder(required_tools)
        end

        result
      end

      private

      # Validate tools exist in registry (Plan 025)
      #
      # @param required_tools [Array<String>] Tools needed by the skill
      # @raise [ArgumentError] If any tool is not available
      # @return [void]
      def validate_skill_tools(required_tools)
        required_tools.each do |tool_name|
          next if @chat.tool_registry.has_tool?(tool_name)

          available = @chat.tool_registry.tool_names.join(", ")
          raise ArgumentError,
            "Skill requires tool '#{tool_name}' but it's not available for this agent. " \
              "Available tools: #{available}"
        end
      end

      # Build system reminder for toolset updates (Plan 025)
      #
      # @param new_tools [Array<String>] Tools that were loaded
      # @return [String] System reminder message
      def build_toolset_update_reminder(new_tools)
        # Get non-removable tools that are always included
        non_removable = @chat.tool_registry.non_removable_tool_names.sort

        reminder = "<system-reminder>\n"
        reminder += "Your available tools have been updated by loading this skill.\n\n"
        reminder += "Tools specified by skill:\n"
        new_tools.each do |tool_name|
          reminder += "  - #{tool_name}\n"
        end
        reminder += "\nNon-removable tools (always available):\n"
        non_removable.each do |tool_name|
          reminder += "  - #{tool_name}\n"
        end
        reminder += "\nOnly use tools from these lists. Other tools have been deactivated for this skill.\n"
        reminder += "</system-reminder>"

        reminder
      end

      # Format validation error message
      #
      # @param message [String] Error message
      # @return [String] Formatted error
      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end
    end
  end
end
