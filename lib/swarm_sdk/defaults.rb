# frozen_string_literal: true

module SwarmSDK
  # Centralized configuration defaults for SwarmSDK
  #
  # This module provides well-documented default values for all configurable
  # aspects of the SDK. Values are organized by category and include explanations
  # for their purpose and rationale.
  #
  # @example Accessing defaults
  #   SwarmSDK::Defaults::Timeouts::AGENT_REQUEST_SECONDS
  #   SwarmSDK::Defaults::Concurrency::GLOBAL_LIMIT
  #   SwarmSDK::Defaults::Limits::OUTPUT_CHARACTERS
  module Defaults
    # Concurrency limits for parallel execution
    #
    # These limits prevent overwhelming external services and ensure
    # fair resource usage across the system.
    module Concurrency
      # Maximum concurrent API calls across entire swarm
      #
      # This limits total parallel LLM API requests to prevent rate limiting
      # and excessive resource consumption. 50 is a balanced value that allows
      # good parallelism while respecting API rate limits.
      GLOBAL_LIMIT = 50

      # Maximum parallel tool executions per agent
      #
      # Limits concurrent tool calls within a single agent. 10 allows
      # meaningful parallelism (e.g., reading multiple files) without
      # overwhelming the system.
      LOCAL_LIMIT = 10
    end

    # Timeout values for various operations
    #
    # All timeouts are in seconds unless explicitly marked as milliseconds.
    # Timeouts balance responsiveness with allowing enough time for operations
    # to complete successfully.
    module Timeouts
      # LLM API request timeout (seconds)
      #
      # Default timeout for Claude/GPT API calls. 5 minutes accommodates
      # reasoning models (o1, Claude with extended thinking) which can take
      # longer to process complex queries.
      AGENT_REQUEST_SECONDS = 300

      # Bash command execution timeout (milliseconds)
      #
      # Default timeout for shell commands. 2 minutes balances allowing
      # build/test commands while preventing runaway processes.
      BASH_COMMAND_MS = 120_000

      # Maximum Bash command timeout (milliseconds)
      #
      # Hard upper limit for bash commands. 10 minutes prevents indefinitely
      # running commands while allowing long builds/tests.
      BASH_COMMAND_MAX_MS = 600_000

      # Web fetch timeout (seconds)
      #
      # Timeout for HTTP requests in WebFetch tool. 30 seconds is standard
      # for web requests, allowing slow servers while timing out unresponsive ones.
      WEB_FETCH_SECONDS = 30

      # Shell hook executor timeout (seconds)
      #
      # Default timeout for hook shell commands. 60 seconds allows complex
      # pre/post hooks while preventing indefinite blocking.
      HOOK_SHELL_SECONDS = 60

      # Workflow transformer command timeout (seconds)
      #
      # Timeout for input/output transformer bash commands. 60 seconds allows
      # data transformation operations while preventing stalls.
      TRANSFORMER_COMMAND_SECONDS = 60

      # OpenAI responses API ID TTL (seconds)
      #
      # Time-to-live for cached response IDs. 5 minutes allows conversation
      # continuity while preventing stale cache issues.
      RESPONSES_API_TTL_SECONDS = 300
    end

    # Output and content size limits
    #
    # These limits prevent overwhelming context windows and ensure
    # reasonable memory usage.
    module Limits
      # Maximum Bash output characters
      #
      # Truncates command output to prevent overwhelming agent context.
      # 30,000 characters balances useful information with context constraints.
      OUTPUT_CHARACTERS = 30_000

      # Default lines to read from files
      #
      # When no explicit limit is set, Read tool returns first 2000 lines.
      # This provides substantial file content while preventing huge files
      # from overwhelming context.
      READ_LINES = 2000

      # Maximum characters per line in Read output
      #
      # Truncates very long lines to prevent single lines from consuming
      # excessive context. 2000 characters per line is generous while
      # protecting against minified files.
      LINE_CHARACTERS = 2000

      # Maximum WebFetch content length
      #
      # Limits web content fetched from URLs. 100,000 characters provides
      # substantial page content while preventing huge pages from overwhelming context.
      WEB_FETCH_CHARACTERS = 100_000

      # Maximum Glob search results
      #
      # Limits number of file paths returned by Glob tool. 1000 results
      # provides comprehensive search while preventing overwhelming output.
      GLOB_RESULTS = 1000
    end

    # Storage limits for persistent data
    module Storage
      # Maximum size for single scratchpad entry (bytes)
      #
      # 3MB per entry prevents individual entries from consuming excessive storage
      # while allowing substantial content (code, large texts).
      ENTRY_SIZE_BYTES = 3_000_000

      # Maximum total scratchpad storage (bytes)
      #
      # 100GB total storage provides ample room for extensive projects
      # while preventing unbounded growth.
      TOTAL_SIZE_BYTES = 100_000_000_000
    end

    # Context management settings
    module Context
      # Context usage percentage triggering compression warning
      #
      # When context usage reaches 60%, agents should consider compaction.
      # This threshold provides buffer before hitting limits.
      COMPRESSION_THRESHOLD_PERCENT = 60

      # Message count between TodoWrite reminders
      #
      # After 8 messages without using TodoWrite, a gentle reminder is injected.
      # Balances helpfulness without being annoying.
      TODOWRITE_REMINDER_INTERVAL = 8
    end

    # Token estimation factors
    #
    # Used for approximate token counting when precise counts aren't available.
    module TokenEstimation
      # Characters per token for prose text
      #
      # Average of ~4 characters per token for natural language text.
      # Based on empirical analysis of tokenization patterns.
      CHARS_PER_TOKEN_PROSE = 4.0

      # Characters per token for code
      #
      # Code tends to have shorter tokens due to symbols and operators.
      # ~3.5 characters per token accounts for this density.
      CHARS_PER_TOKEN_CODE = 3.5
    end

    # Logging configuration
    module Logging
      # Default MCP client log level
      #
      # WARN level suppresses verbose MCP client logs while still
      # reporting important issues.
      MCP_LOG_LEVEL = Logger::WARN
    end

    # Agent configuration defaults
    #
    # Default values for agent configuration when not explicitly specified.
    module Agent
      # Default LLM model identifier
      #
      # OpenAI's GPT-5 is used as the default model. This can be overridden
      # per-agent or globally via all_agents configuration.
      MODEL = "gpt-5"

      # Default LLM provider
      #
      # OpenAI is the default provider. Supported providers include:
      # openai, anthropic, gemini, deepseek, openrouter, bedrock, etc.
      PROVIDER = "openai"
    end
  end
end
