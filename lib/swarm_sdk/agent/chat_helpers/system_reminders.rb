# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # System reminder collection and injection
      #
      # Extracted from Chat to reduce class size and centralize reminder logic.
      module SystemReminders
        # Collect reminders from all plugins
        #
        # @param prompt [String] User's message
        # @param is_first_message [Boolean] True if first message
        # @return [Array<String>] Array of reminder strings
        def collect_plugin_reminders(prompt, is_first_message:)
          return [] unless @agent_name

          PluginRegistry.all.flat_map do |plugin|
            plugin.on_user_message(
              agent_name: @agent_name,
              prompt: prompt,
              is_first_message: is_first_message,
            )
          end.compact
        end

        # Collect all system reminders for this message
        #
        # Returns an array of reminder strings that should be injected as ephemeral content.
        # These are sent to the LLM but not stored in message history.
        #
        # @param prompt [String] User prompt
        # @param is_first [Boolean] Whether this is the first message
        # @return [Array<String>] Array of reminder strings
        def collect_system_reminders(prompt, is_first)
          reminders = []

          if is_first
            # Add toolset reminder on first message
            reminders << build_toolset_reminder

            # Add todo list reminder if agent has TodoWrite tool
            reminders << SystemReminderInjector::AFTER_FIRST_MESSAGE_REMINDER if has_tool?(:TodoWrite)

            # Collect plugin reminders
            reminders.concat(collect_plugin_reminders(prompt, is_first_message: true))
          else
            # Add periodic TodoWrite reminder if needed
            if has_tool?(:TodoWrite) && SystemReminderInjector.should_inject_todowrite_reminder?(self, @last_todowrite_message_index)
              reminders << SystemReminderInjector::TODOWRITE_PERIODIC_REMINDER
              @last_todowrite_message_index = SystemReminderInjector.find_last_todowrite_index(self)
            end

            # Collect plugin reminders
            reminders.concat(collect_plugin_reminders(prompt, is_first_message: false))
          end

          reminders
        end

        private

        # Build toolset reminder listing all available tools
        #
        # @return [String] System reminder with tool list
        def build_toolset_reminder
          tools_list = tool_names

          reminder = "<system-reminder>\n"
          reminder += "Tools available: #{tools_list.join(", ")}\n\n"
          reminder += "Only use tools from this list. Do not attempt to use tools that are not listed here.\n"
          reminder += "</system-reminder>"

          reminder
        end
      end
    end
  end
end
