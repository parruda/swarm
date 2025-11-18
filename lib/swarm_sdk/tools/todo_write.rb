# frozen_string_literal: true

module SwarmSDK
  module Tools
    # TodoWrite tool for creating and managing structured task lists
    #
    # This tool helps agents track progress on complex multi-step tasks.
    # Each agent maintains its own independent todo list.
    class TodoWrite < RubyLLM::Tool
      # Factory pattern: declare what parameters this tool needs for instantiation
      class << self
        def creation_requirements
          [:agent_name]
        end
      end

      description <<~DESC
        Use this tool to create and manage a structured task list for your current work session. This helps you track progress, organize complex tasks, and demonstrate thoroughness to the user.
        It also helps the user understand the progress of the task and overall progress of their requests.

        ## When to Use This Tool
        Use this tool proactively in these scenarios:

        **CRITICAL**: Follow this workflow for multi-step tasks:
        1. FIRST: Analyze the task scope (gather information, understand requirements)
        2. SECOND: Create a COMPLETE todo list with ALL known tasks BEFORE starting work
        3. THIRD: Execute tasks, marking in_progress → completed as you work
        4. ONLY add new todos if unexpected work is discovered during execution

        Use the todo list when:
        1. Complex multi-step tasks - When a task requires 3 or more distinct steps or actions
        2. Non-trivial and complex tasks - Tasks that require careful planning or multiple operations
        3. User explicitly requests todo list - When the user directly asks you to use the todo list
        4. User provides multiple tasks - When users provide a list of things to be done (numbered or comma-separated)
        5. After receiving new instructions - After analyzing scope, create complete todo list before starting work
        6. When you start working on a task - Mark it as in_progress BEFORE beginning work. Ideally you should only have one todo as in_progress at a time
        7. After completing a task - Mark it as completed and add any new follow-up tasks discovered during execution

        ## When NOT to Use This Tool

        Skip using this tool when:
        1. There is only a single, straightforward task
        2. The task is trivial and tracking it provides no organizational benefit
        3. The task can be completed in less than 3 trivial steps
        4. The task is purely conversational or informational

        NOTE that you should not use this tool if there is only one trivial task to do. In this case you are better off just doing the task directly.

        ## Task States and Management

        1. **Task States**: Use these states to track progress:
          - pending: Task not yet started
          - in_progress: Currently working on (limit to ONE task at a time)
          - completed: Task finished successfully

          **IMPORTANT**: Task descriptions must have two forms:
          - content: The imperative form describing what needs to be done (e.g., "Run tests", "Build the project")
          - activeForm: The present continuous form shown during execution (e.g., "Running tests", "Building the project")

        2. **Task Management**:
          - Update task status in real-time as you work
          - Mark tasks complete IMMEDIATELY after finishing (don't batch completions)
          - Exactly ONE task must be in_progress at any time (not less, not more)
          - Complete current tasks before starting new ones
          - Remove tasks that are no longer relevant from the list entirely
          - **CRITICAL**: You MUST complete ALL pending todos before giving your final answer to the user
          - NEVER leave in_progress or pending tasks when you finish responding

        3. **Task Completion Requirements**:
          - ONLY mark a task as completed when you have FULLY accomplished it
          - If you encounter errors, blockers, or cannot finish, keep the task as in_progress
          - When blocked, create a new task describing what needs to be resolved
          - Never mark a task as completed if:
            - Tests are failing
            - Implementation is partial
            - You encountered unresolved errors
            - You couldn't find necessary files or dependencies

        4. **Task Breakdown**:
          - Create specific, actionable items
          - Break complex tasks into smaller, manageable steps
          - Use clear, descriptive task names
          - Always provide both forms (content and activeForm)

        ## Examples

        **Coding Tasks**:
        - content: "Fix authentication bug in login handler"
        - activeForm: "Fixing authentication bug in login handler"

        **Non-Coding Tasks**:
        - content: "Analyze customer feedback from Q4 survey"
        - activeForm: "Analyzing customer feedback from Q4 survey"

        **Research Tasks**:
        - content: "Research best practices for API rate limiting"
        - activeForm: "Researching best practices for API rate limiting"

        When in doubt, use this tool. Being proactive with task management demonstrates attentiveness and ensures you complete all requirements successfully.
      DESC

      param :todos_json,
        type: "string",
        desc: <<~DESC.chomp,
          JSON array of todo objects. Each todo must have:
          content (string, task in imperative form like 'Run tests'),
          status (string, one of: 'pending', 'in_progress', 'completed'),
          activeForm (string, task in present continuous form like 'Running tests').
          Example: [{"content":"Read file","status":"pending","activeForm":"Reading file"}]
        DESC
        required: true

      # Initialize the TodoWrite tool for a specific agent
      #
      # @param agent_name [Symbol, String] The agent identifier
      def initialize(agent_name:)
        super()
        @agent_name = agent_name.to_sym
      end

      # Override name to return simple "TodoWrite" instead of full class path
      def name
        "TodoWrite"
      end

      def execute(todos_json:)
        # Parse JSON
        todos = begin
          JSON.parse(todos_json)
        rescue JSON::ParserError
          nil
        end

        return validation_error("Invalid JSON format. Please provide a valid JSON array of todo objects.") if todos.nil?

        # Validate todos structure
        unless todos.is_a?(Array)
          return validation_error("todos must be an array of todo objects")
        end

        if todos.empty?
          return validation_error("todos array cannot be empty")
        end

        validated_todos = []
        errors = []

        todos.each_with_index do |todo, index|
          unless todo.is_a?(Hash)
            errors << "Todo at index #{index} must be a hash/object"
            next
          end

          # Convert string keys to symbols for consistency
          todo = todo.transform_keys(&:to_sym) if todo.is_a?(Hash)

          # Validate required fields
          unless todo[:content]
            errors << "Todo at index #{index} missing required field 'content'"
            next
          end

          unless todo[:status]
            errors << "Todo at index #{index} missing required field 'status'"
            next
          end

          unless todo[:activeForm]
            errors << "Todo at index #{index} missing required field 'activeForm'"
            next
          end

          # Validate status values
          valid_statuses = ["pending", "in_progress", "completed"]
          unless valid_statuses.include?(todo[:status].to_s)
            errors << "Todo at index #{index} has invalid status '#{todo[:status]}'. Must be one of: #{valid_statuses.join(", ")}"
            next
          end

          # Validate content and activeForm are non-empty
          if todo[:content].to_s.strip.empty?
            errors << "Todo at index #{index} has empty content"
            next
          end

          if todo[:activeForm].to_s.strip.empty?
            errors << "Todo at index #{index} has empty activeForm"
            next
          end

          validated_todos << {
            content: todo[:content].to_s,
            status: todo[:status].to_s,
            activeForm: todo[:activeForm].to_s,
          }
        end

        return validation_error("TodoWrite failed due to the following issues:\n#{errors.join("\n")}") unless errors.empty?

        # Check that exactly one task is in_progress (with helpful message)
        in_progress_count = validated_todos.count { |t| t[:status] == "in_progress" }
        warning_message = if in_progress_count == 0
          "Warning: No tasks marked as in_progress. You should have exactly ONE task in_progress at a time.\n" \
            "Please mark the task you're currently working on as in_progress.\n\n"
        elsif in_progress_count > 1
          "Warning: Multiple tasks marked as in_progress (#{in_progress_count} tasks).\n" \
            "You should have exactly ONE task in_progress at a time.\n" \
            "Please ensure only the current task is in_progress, others should be pending or completed.\n\n"
        else
          ""
        end

        # Store the validated todos
        Stores::TodoManager.set_todos(@agent_name, validated_todos)

        <<~RESPONSE
          <system-reminder>
          #{warning_message}Your todo list has changed. DO NOT mention this explicitly to the user. Here are the latest contents of your todo list:
          #{validated_todos.map { |t| "- #{t[:content]} (#{t[:status]})" }.join("\n")}
          Keep going with the tasks at hand if applicable.
          </system-reminder>
        RESPONSE
      rescue StandardError => e
        "Error managing todos: #{e.class.name} - #{e.message}"
      end

      private

      # Helper method for validation errors
      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end
    end
  end
end
