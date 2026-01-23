# frozen_string_literal: true

# Extends RubyLLM::Chat with enhanced message management:
# - reset_messages! with preserve_system_prompt option
#
# Fork Reference: Commit e6a34b5

module RubyLLM
  class Chat
    # Override reset_messages! to support preserve_system_prompt option
    #
    # @param preserve_system_prompt [Boolean] If true (default), keeps system messages
    # @return [self] for chaining
    def reset_messages!(preserve_system_prompt: true)
      if preserve_system_prompt
        @messages.select! { |m| m.role == :system }
      else
        @messages.clear
      end
      self
    end
  end
end
