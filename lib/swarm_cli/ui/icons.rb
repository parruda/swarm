# frozen_string_literal: true

module SwarmCLI
  module UI
    # Icon definitions for terminal UI
    # Centralized so all components use the same icons
    module Icons
      # Event type icons
      THINKING = "💭"
      RESPONSE = "💬"
      SUCCESS = "✓"
      ERROR = "✗"
      INFO = "ℹ"
      WARNING = "⚠️"

      # Entity icons
      AGENT = "🤖"
      TOOL = "🔧"
      DELEGATE = "📨"
      RESULT = "📥"
      HOOK = "🪝"

      # Metric icons
      LLM = "🧠"
      TOKENS = "📊"
      COST = "💰"
      TIME = "⏱"

      # Visual elements
      SPARKLES = "✨"
      ARROW_RIGHT = "→"
      BULLET = "•"
      COMPRESS = "🗜️"
    end
  end
end
