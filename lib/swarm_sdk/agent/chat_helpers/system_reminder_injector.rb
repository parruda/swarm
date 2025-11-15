# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # Handles injection of system reminders at strategic points in the conversation
      #
      # Responsibilities:
      # - Inject reminders before/after first user message
      # - Inject periodic TodoWrite reminders
      # - Track when reminders were last injected
      #
      # This class is stateless - it operates on the chat's message history.
      class SystemReminderInjector
        # System reminder to inject AFTER the first user message
        AFTER_FIRST_MESSAGE_REMINDER = <<~REMINDER.strip
          <system-reminder>Your todo list is currently empty. DO NOT mention this to the user. If this task requires multiple steps: (1) FIRST analyze the scope by searching/reading files, (2) SECOND create a COMPLETE todo list with ALL tasks before starting work, (3) THIRD execute tasks one by one. Only skip the todo list for simple single-step tasks. Do not mention this message to the user.</system-reminder>
        REMINDER

        # Periodic reminder about TodoWrite tool usage
        TODOWRITE_PERIODIC_REMINDER = <<~REMINDER.strip
          <system-reminder>The TodoWrite tool hasn't been used recently. If you're working on tasks that would benefit from tracking progress, consider using the TodoWrite tool to track progress. Also consider cleaning up the todo list if has become stale and no longer matches what you are working on. Only use it if it's relevant to the current work. This is just a gentle reminder - ignore if not applicable.</system-reminder>
        REMINDER

        # Backward compatibility alias - use Defaults module for new code
        TODOWRITE_REMINDER_INTERVAL = Defaults::Context::TODOWRITE_REMINDER_INTERVAL

        class << self
          # Check if this is the first user message in the conversation
          #
          # @param chat [Agent::Chat] The chat instance
          # @return [Boolean] true if no user messages exist yet
          def first_message?(chat)
            !chat.has_user_message?
          end

          # Inject first message reminders
          #
          # This manually constructs the first message sequence with system reminders.
          #
          # Sequence:
          # 1. User's actual prompt
          # 2. Toolset reminder (list of available tools)
          # 3. AFTER_FIRST_MESSAGE_REMINDER (todo list reminder - only if TodoWrite available)
          #
          # @param chat [Agent::Chat] The chat instance
          # @param prompt [String] The user's actual prompt
          # @return [void]
          def inject_first_message_reminders(chat, prompt)
            # Build user message with embedded reminders
            # Reminders are embedded in the content, not separate messages
            parts = [
              prompt,
              build_toolset_reminder(chat),
            ]

            # Only include todo list reminder if agent has TodoWrite tool
            parts << AFTER_FIRST_MESSAGE_REMINDER if chat.has_tool?("TodoWrite")

            full_content = parts.join("\n\n")

            # Extract reminders and add clean prompt to persistent history
            reminders = chat.context_manager.extract_system_reminders(full_content)
            clean_prompt = chat.context_manager.strip_system_reminders(full_content)

            # Store clean prompt (without reminders) in conversation history
            chat.add_message(role: :user, content: clean_prompt)

            # Track reminders to embed in this message when sending to LLM
            reminders.each do |reminder|
              chat.context_manager.add_ephemeral_reminder(reminder, messages_array: chat.internal_messages)
            end
          end

          # Build toolset reminder listing all available tools
          #
          # @param chat [Agent::Chat] The chat instance
          # @return [String] System reminder with tool list
          def build_toolset_reminder(chat)
            tools_list = chat.tool_names

            reminder = "<system-reminder>\n"
            reminder += "Tools available: #{tools_list.join(", ")}\n\n"
            reminder += "Only use tools from this list. Do not attempt to use tools that are not listed here.\n"
            reminder += "</system-reminder>"

            reminder
          end

          # Check if we should inject a periodic TodoWrite reminder
          #
          # Injects a reminder if:
          # 1. Enough messages have passed (>= 5)
          # 2. TodoWrite hasn't been used in the last TODOWRITE_REMINDER_INTERVAL messages
          #
          # @param chat [Agent::Chat] The chat instance
          # @param last_todowrite_index [Integer, nil] Index of last TodoWrite usage
          # @return [Boolean] true if reminder should be injected
          def should_inject_todowrite_reminder?(chat, last_todowrite_index)
            # Need at least a few messages before reminding
            return false if chat.message_count < 5

            # Find the last message that contains TodoWrite tool usage
            last_todo_index = chat.internal_messages.rindex do |msg|
              msg.role == :tool && msg.content.to_s.include?("TodoWrite")
            end

            # Check if enough messages have passed since last TodoWrite
            if last_todo_index.nil? && last_todowrite_index.nil?
              # Never used TodoWrite - check if we've exceeded interval
              chat.message_count >= TODOWRITE_REMINDER_INTERVAL
            elsif last_todo_index
              # Recently used - don't remind
              false
            elsif last_todowrite_index
              # Used before - check if interval has passed
              chat.message_count - last_todowrite_index >= TODOWRITE_REMINDER_INTERVAL
            else
              false
            end
          end

          # Update the last TodoWrite index by finding it in messages
          #
          # @param chat [Agent::Chat] The chat instance
          # @return [Integer, nil] Index of last TodoWrite usage, or nil
          def find_last_todowrite_index(chat)
            chat.internal_messages.rindex do |msg|
              msg.role == :tool && msg.content.to_s.include?("TodoWrite")
            end
          end
        end
      end
    end
  end
end
