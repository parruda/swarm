# frozen_string_literal: true

# RubyLLM Compatibility Patches
#
# These patches extend upstream ruby_llm to match fork functionality used by SwarmSDK.
# Load order is important - patches are loaded in dependency order.
#
# Features provided by these patches:
# - Multi-subscriber callbacks with Subscription objects
# - around_tool_execution and around_llm_request hooks
# - Concurrent tool execution (async/threads)
# - preserve_system_prompt option in reset_messages!
# - Configurable Anthropic API base URL
# - Granular timeout configuration (read_timeout, open_timeout, write_timeout)
# - OpenAI Responses API support
# - IPv6 fallback fix for io-endpoint
#
# Once upstream ruby_llm adds these features, patches can be disabled.

# Load patches in dependency order

# 1. io-endpoint patch (infrastructure fix, no RubyLLM dependencies)
require_relative "io_endpoint_patch"

# 2. Configuration patch (must be loaded before connection/providers)
require_relative "configuration_patch"

# 3. Connection patch (depends on configuration patch)
require_relative "connection_patch"

# 4. Chat callbacks patch (core callback system)
require_relative "chat_callbacks_patch"

# 5. Tool concurrency patch (depends on chat callbacks patch)
require_relative "tool_concurrency_patch"

# 6. Message management patch (simple, no dependencies)
require_relative "message_management_patch"

# 7. Responses API patch (depends on configuration, uses error classes)
require_relative "responses_api_patch"
