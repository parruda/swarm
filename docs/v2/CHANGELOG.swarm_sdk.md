# Changelog

All notable changes to SwarmSDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.7.12]

### Added

- **Extended thinking support**: New `thinking` DSL method for agents and `all_agents`. Enables chain-of-thought reasoning for supported models:
  - Anthropic (Claude): `thinking budget: 10_000` — sets token budget for thinking output
  - OpenAI (o-series): `thinking effort: :high` — sets reasoning effort level
  - Cross-provider: both `effort` and `budget` can be specified for portability
  - YAML support: `thinking.budget` and `thinking.effort` keys
  - `all_agents` support: set swarm-wide thinking defaults
  - **Files**: `agent/builder.rb`, `agent/definition.rb`, `agent/chat.rb`, `agent/chat_helpers/llm_configuration.rb`, `swarm/all_agents_builder.rb`, `builders/base_builder.rb`, `configuration/translator.rb`

### Fixed

- **`unknown keyword: :thinking` error**: The `perform_llm_request` method now only passes `thinking:` to the provider when explicitly configured. Previously it always passed `thinking: nil` which caused `ArgumentError` on RubyLLM versions where `Provider#complete` doesn't accept this keyword.
  - **Files**: `ruby_llm_patches/chat_callbacks_patch.rb`
- **Programming errors no longer retried**: `ArgumentError`, `TypeError`, and `NameError` are now non-retryable in `call_llm_with_retry`. Previously these fell into the `StandardError` catch-all and were retried 3 times with 15-second delays.
  - **Files**: `agent/chat.rb`

## [2.7.11]

### Changed

- **Migrate from `ruby_llm_swarm` fork to upstream `ruby_llm` (~> 1.11)**: Replaced the custom fork dependency with the official `ruby_llm` gem, adding monkey patches to preserve fork-specific features:
  - `chat_callbacks_patch` - Multi-subscriber callbacks with Subscription objects, `around_tool_execution` and `around_llm_request` hooks
  - `tool_concurrency_patch` - Concurrent tool execution (async/threads)
  - `message_management_patch` - `preserve_system_prompt` option in `reset_messages!`
  - `configuration_patch` - Configurable Anthropic API base URL and granular timeouts
  - `connection_patch` - Apply timeout config to Faraday connections
  - `responses_api_patch` - OpenAI Responses API support
  - `io_endpoint_patch` - IPv6 fallback fix for io-endpoint
  - **Files**: `lib/swarm_sdk/ruby_llm_patches/`, `swarm_sdk.gemspec`, `swarm_memory.gemspec`
- **Removed `openssl` gem dependency** from swarm_sdk.gemspec (no longer needed)

### Fixed

- **Sub-swarm delegation lazy initialization**: Sub-swarm agents weren't initialized before accessing the lead agent, causing `NoMethodError` when delegating to agents in included swarms. Uses `Swarm#agent()` instead of direct hash access to ensure initialization.
  - **Files**: `lib/swarm_sdk/tools/delegate.rb`
- **Zeitwerk eager loading outside Rails**: Ignore RubyLLM's ActiveRecord integration and the `ruby_llm_patches` directory during Zeitwerk eager loading to prevent `NameError` in non-Rails applications.
  - **Files**: `lib/swarm_sdk.rb`

## [2.7.10]

### Added

- **Lazy Loading for Delegation Agents**: Delegation instances are now lazily initialized on first use
  - **Performance improvement**: Agents are only created when their delegation is first called, not at swarm startup
  - **New class**: `LazyDelegateChat` - Thread-safe wrapper that defers agent creation until first use
  - **New events**: `agent_lazy_initialization_start` and `agent_lazy_initialization_complete` for monitoring
  - **New Delegate tool methods**:
    - `lazy?` - Returns true if using lazy loading
    - `initialized?` - Returns true if the delegate has been initialized
    - `initialize_delegate!` - Forces initialization
  - **New Swarm method**: `initialize_lazy_delegates!` - Forces initialization of all lazy delegates (useful for testing or preloading)
  - **Nested delegation support**: Cascading lazy initialization for delegation chains (A → B → C)
  - **Shared delegates unchanged**: Delegates with `shared_across_delegations: true` still use immediate initialization
  - **Files**: `lib/swarm_sdk/swarm/lazy_delegate_chat.rb`, `lib/swarm_sdk/swarm/agent_initializer.rb`, `lib/swarm_sdk/tools/delegate.rb`, `lib/swarm_sdk/swarm.rb`

## [2.7.9]
- Updated models.json


## [2.7.8]
- Parallel agent initialization

## [2.7.7]

### Improved

- **MCP Error Messages with Context**: MCP errors now include detailed context for easier debugging
  - **Error types**: `MCPTimeoutError`, `MCPTransportError`, `MCPError` (base class)
  - **Context included**: Server name, tool name, request ID (for timeouts), HTTP code (for transport errors)
  - **Example**: `MCP request timed out [server: codebase_server] [tool: search_code] [request_id: req_123] - Request timed out after 30 seconds`
  - **Coverage**: Both tool execution (`execute`) and schema loading (`params_schema`) now wrap MCP errors
  - **Files**: `lib/swarm_sdk.rb` (error classes), `lib/swarm_sdk/tools/mcp_tool_stub.rb`, `lib/swarm_sdk/swarm/mcp_configurator.rb`

## [2.7.6]

- **MCP Server Initialization Events**: New events emitted during MCP server setup for monitoring and debugging
  - `mcp_server_init_start` - Emitted before MCP server initialization begins
  - `mcp_server_init_complete` - Emitted after successful MCP server initialization
  - **Event fields**: `agent`, `server_name`, `transport_type`, `mode` (`:discovery` or `:optimized`), `tool_count`, `tools`
  - **Files**: `lib/swarm_sdk/swarm/mcp_configurator.rb`
- Only extracts JPEG images (DCTDecode format) which are LLM API compatible

## [2.7.5] - 2026-01-14

### Added

- **Configurable LLM Connection Timeouts**: Fine-grained control over RubyLLM connection timeouts
  - **New configuration options**:
    - `llm_request_timeout` (default: 300s) - Maximum time for entire LLM request
    - `llm_read_timeout` (default: nil, uses request_timeout) - Time between data chunks (critical for streaming)
    - `llm_open_timeout` (default: 30s) - Connection establishment timeout
    - `llm_write_timeout` (default: 30s) - Write operation timeout
  - **Environment variables**:
    - `SWARM_SDK_LLM_REQUEST_TIMEOUT`
    - `SWARM_SDK_LLM_READ_TIMEOUT`
    - `SWARM_SDK_LLM_OPEN_TIMEOUT`
    - `SWARM_SDK_LLM_WRITE_TIMEOUT`
  - **Automatic RubyLLM proxying**: Settings automatically applied to RubyLLM.config
  - **Streaming fix**: `read_timeout` now automatically set to match `request_timeout` in custom contexts
    - Prevents timeouts during long pauses between chunks (model thinking time)
    - Critical for streaming responses where gaps between chunks can be long
  - **Use case**: Customize timeout behavior per deployment environment or specific model requirements
  - **Configuration example**:
    ```ruby
    SwarmSDK.configure do |config|
      config.llm_request_timeout = 600  # 10 minutes for complex requests
      config.llm_read_timeout = 600     # Allow long gaps between chunks
      config.llm_open_timeout = 60      # Allow slower connection establishment
    end
    ```
  - **Files**: `lib/swarm_sdk/config.rb`, `lib/swarm_sdk/agent/chat_helpers/llm_configuration.rb`

### Dependencies

- Updated `ruby_llm_swarm` to `~> 1.9.7`

## [2.7.4] - 2025-12-17

### Added

- **Delegation `reset_context` Parameter**: Dynamic per-call context reset for recovering from errors
  - **New optional parameter**: `reset_context` (boolean, defaults to `false`) on delegation tool calls
  - **Use case**: Recover from "prompt too long" errors or other 4XX errors by resetting child agent's conversation history
  - **Description**: "Reset the agent's conversation history before sending the message. Use it to recover from 'prompt too long' errors or other 4XX errors."
  - **Runtime override**: Takes precedence over `preserve_context` configuration when explicitly set to `true`
  - **Backward compatible**: Omitting parameter maintains existing behavior (respects `preserve_context` setting)
  - **Parent agent pattern**: Parent receives error message explaining context overflow, can reset and retry with adjusted instructions
  - **Usage example**:
    ```ruby
    # First attempt hits context limit
    WorkWithBackend(message: "Analyze all files")
    # Returns: "This agent exceeded its context window limit..."

    # Parent resets and retries with better guidance
    WorkWithBackend(
      message: "Analyze files, but use fewer parallel tool calls",
      reset_context: true
    )
    ```
  - **Logic**:
    - `reset_context: true` → Always clears conversation (explicit reset)
    - `reset_context: false` + `preserve_context: true` → Preserves conversation (default)
    - `reset_context: false` + `preserve_context: false` → Clears conversation (standard behavior)
  - **Supports both delegation types**: Works with agent-to-agent and swarm-to-swarm delegation
  - **Files**: `lib/swarm_sdk/tools/delegate.rb` (updated `execute`, `delegate_to_agent`, `delegate_to_swarm` methods)
  - **Tests**: 8 comprehensive tests covering parameter schema, behavior with various `preserve_context` settings, multiple resets, and backward compatibility

## [2.7.3] - 2025-12-14

### Added

- **Delegation `preserve_context` Option**: Control whether delegated agents preserve conversation history between delegations
  - **Default behavior (`true`)**: Delegated agent preserves conversation history across multiple delegations (existing behavior)
  - **New option (`false`)**: Clears delegated agent's conversation before each delegation call
  - **Use case**: Stateless delegation where each call should start fresh without prior context
  - **DSL syntax**:
    ```ruby
    delegates_to :backend  # preserve_context: true (default)
    delegates_to({ agent: :backend, preserve_context: false })
    delegates_to :frontend, { agent: :backend, preserve_context: false, tool_name: "AskBackend" }
    ```
  - **YAML syntax**:
    ```yaml
    delegates_to:
      - agent: backend
        preserve_context: false
      - agent: frontend
        tool_name: AskFrontend
      - database  # preserve_context: true (default)
    ```
  - **Backward compatible**: All existing delegation formats work unchanged with `preserve_context: true` default
  - **Files**: `lib/swarm_sdk/agent/builder.rb`, `lib/swarm_sdk/agent/definition.rb`, `lib/swarm_sdk/tools/delegate.rb`, `lib/swarm_sdk/swarm/agent_initializer.rb`
  - **Tests**: 9 comprehensive tests covering DSL, YAML, and tool behavior

## [2.7.2] - 2025-12-13

### Fixed

- **Citation chunk emission during streaming**: Fixed citation chunks not being emitted during streaming responses
  - Issue: `emit_citations_chunk()` call was accidentally removed during code cleanup
  - Fix: Restored citation chunk emission in `trigger_agent_stop()` when streaming enabled
  - Impact: Citation chunks with `chunk_type: "citations"` now correctly emitted after content streaming
  - Location: `lib/swarm_sdk/agent/chat_helpers/context_tracker.rb:337-340`

## [2.7.1] - 2025-12-13

### Added

- **Citations and Search Results Support**: Automatic extraction and formatting for LLM responses with citations
  - **Event fields**: `citations` (array of URLs) and `search_results` (array of objects) in `agent_stop` and `agent_step` events
  - **Content formatting**: Citations automatically appended to response content as numbered markdown list:
    ```markdown
    Answer based on sources...

    # Citations
    - [1] https://www.ruby-lang.org/...
    - [2] https://en.wikipedia.org/...
    ```
  - **Streaming support**: Citations chunk emitted with `chunk_type: "citations"` after content streaming completes
  - **Provider support**: Works with any provider returning citations (Perplexity sonar, etc.)
  - **Extraction logic**:
    - Non-streaming: Extracts from `message.raw.body["citations"]`
    - Streaming: Falls back to `Fiber[:last_sse_body]` set by middleware
    - Handles Hash, String JSON, and SSE formats
    - Graceful error handling (returns empty if extraction fails)
  - **Files**: `lib/swarm_sdk/agent/chat_helpers/context_tracker.rb`, `lib/swarm_sdk/swarm/logging_callbacks.rb`
  - **Tests**: 13 comprehensive tests, all passing (42 assertions)

- **Comprehensive Streaming Test Suite**: 41 new tests validating streaming functionality with real SSE mocking
  - **SSE Response Fixtures** (`test/fixtures/sse_responses.rb`): Realistic Server-Sent Events fixtures
    - `openai_stream()` - OpenAI-style SSE generation with deltas
    - `simple_content_stream()` - Easy content-only streaming helper
    - `tool_call_stream()` - Tool call streaming with partial JSON arguments
    - `content_then_tool_stream()` - Mixed content→tool_call transitions
  - **Real SSE Mocking**: Discovered WebMock DOES support SSE streaming with proper format
    - `stub_streaming_llm()` helper in LLMMockHelper
    - Returns SSE format with `Content-Type: text/event-stream` headers
    - RubyLLM streaming callbacks actually fire in tests!
  - **Test Coverage**:
    - Configuration tests: global, per-agent, ENV vars, YAML inheritance (11 tests)
    - Event emission: content_chunk events with real SSE (6 tests)
    - Integration: delegation, ephemeral cleanup, middleware (15 tests)
    - YAML configuration: all_agents config, agent override (3 tests)
    - Edge cases: event filtering, snapshot compatibility (6 tests)
  - **All 2010 tests passing** with streaming enabled by default in production
  - **Test infrastructure**: `after_setup` hook auto-disables streaming for WebMock compatibility

### Fixed

- **all_agents streaming inheritance**: Fixed streaming not being applied from all_agents block
  - Added `streaming()` method to `AllAgentsBuilder`
  - Added streaming merge logic in `BaseBuilder#apply_all_agents_defaults`
  - YAML `all_agents: streaming: true` now correctly propagates to agents

## [2.7.0] - 2025-12-11

### Added

- **LLM Response Streaming**: Real-time content delivery with intelligent chunk type detection
  - **Enabled by default**: `streaming: true` prevents timeout errors on long responses
  - **Per-agent configuration**: Override via YAML (`streaming: false`) or DSL (`streaming false`)
  - **Global configuration**: `SwarmSDK.config.streaming = false` or `SWARM_SDK_STREAMING=false`
  - **New `content_chunk` event**: Emitted for each streaming chunk with enhanced metadata
    - `chunk_type`: `"content"` (text), `"tool_call"` (tool invocation), or `"separator"` (transition marker)
    - `content`: Text content (nil for tool_call chunks)
    - `tool_calls`: Partial tool call data (nil for content chunks) - **arguments are string fragments!**
    - `model`: Model identifier
    - Auto-injected: `execution_id`, `swarm_id`, `parent_swarm_id`, `timestamp`
  - **Transition detection**: Automatic `separator` event when content chunks switch to tool_call chunks
    - Helps UI distinguish "thinking" text from tool execution
    - Only fires for providers that emit content before tool calls (Anthropic, DeepSeek, Gemini)
    - OpenAI jumps directly to tool_calls, no separator emitted
  - **API compatibility**: `ask()` still returns complete `RubyLLM::Message` after streaming
  - **Subscription example**:
    ```ruby
    LogCollector.subscribe(filter: { type: "content_chunk" }) do |event|
      case event[:chunk_type]
      when "content"
        print event[:content]
      when "separator"
        puts "\n" # Visual break between thinking and tools
      when "tool_call"
        puts "🔧 #{event[:tool_calls].values.first[:name]}"
      end
    end
    ```
  - **YAML configuration**:
    ```yaml
    agents:
      backend:
        model: claude-sonnet-4
        streaming: true  # Enable (default)
      fast_agent:
        model: gpt-4o-mini
        streaming: false  # Disable for fast models
    ```
  - **Files**: `lib/swarm_sdk/agent/chat.rb`, `lib/swarm_sdk/agent/definition.rb`, `lib/swarm_sdk/agent/builder.rb`, `lib/swarm_sdk/config.rb`, `lib/swarm_sdk/configuration/translator.rb`, `lib/swarm_sdk/agent/llm_instrumentation_middleware.rb`
  - **Tests**: All 1969 tests pass with streaming disabled in test suite (WebMock doesn't support SSE)

### Changed

- **`llm_api_response` event enhanced for streaming**:
  - New `streaming: true|false` field indicates response type
  - `status`: HTTP status code now included
  - `body`: Contains full raw SSE stream for streaming responses (all `data:` lines)
  - `body`: Contains JSON response for non-streaming responses (unchanged)
  - Usage/model extracted from last SSE event for streaming responses
  - Middleware wraps `on_data` callback to capture raw chunks before RubyLLM processes them

### Fixed

- **Ephemeral content cleanup on streaming failure**: Now uses `begin/ensure` block
  - **Issue**: Ephemeral content (system reminders) could leak if streaming failed and retries exhausted
  - **Fix**: Moved `clear_ephemeral` to `ensure` block in `setup_llm_request_hook`
  - **Impact**: Prevents memory leaks and stale content in subsequent requests
  - **Benefit**: Improves reliability regardless of streaming (general bug fix)
  - **Location**: `lib/swarm_sdk/agent/chat.rb:789-799`

### Notes

- **Streaming with WebMock**: Tests disable streaming via `SwarmSDK.config.streaming = false` because WebMock returns JSON, not SSE
- **Chunk type mutually exclusive**: Content and tool_calls never appear in same chunk
- **Partial tool call arguments**: `chunk.tool_calls` arguments are raw string fragments during streaming - use `tool_call` event (emitted after streaming completes) for complete parsed data
- **Timeout prevention**: Main benefit of streaming is keeping HTTP connection alive during long responses
- **Known behavior**: Retry may emit duplicate `content_chunk` events (final Message is always correct)

- **Plan 025: Lazy Tool Activation Architecture** - Revolutionary redesign enabling skills to control ALL tool types
  - **Tool Registry System**: Per-agent registry with lazy activation before each LLM request
  - **BaseTool Class**: New base class with `removable` DSL attribute for declarative tool control
  - **ToolRegistry**: Registry-based tool management with source tracking (builtin, delegation, MCP, plugin)
  - **MCP Boot Optimization**: Skip tools/list RPC when tools specified (~300-500ms faster per server)
  - **Symbol Key Support**: `chat.tools[:ToolName]` and `chat.tools["ToolName"]` both work via SymbolKeyHash wrapper
  - **6-Pass Initialization**: Added Pass 6 for tool activation after all plugins registered
  - **Files Added**:
    - `lib/swarm_sdk/tools/base.rb` - Base class with removable DSL
    - `lib/swarm_sdk/agent/tool_registry.rb` - Per-agent tool registry
    - `lib/swarm_sdk/tools/mcp_tool_stub.rb` - Lazy MCP schema loading
    - `test/swarm_sdk/tools/base_test.rb`
    - `test/swarm_sdk/agent/tool_registry_test.rb`
    - `test/swarm_sdk/tools/mcp_tool_stub_test.rb`

- **MCP Server `tools:` Parameter**: Optional tool filtering for faster boot and controlled exposure
  ```yaml
  mcp_servers:
    - name: codebase
      tools: [search_code, list_files]  # Instant boot, lazy schema
  ```

### Changed

- **ALL SDK Tools**: Now inherit from `SwarmSDK::Tools::Base` instead of `RubyLLM::Tool`
  - Think, Clock, TodoWrite marked `removable false` (always available)
  - Read, Write, Edit, Bash, Grep, Glob, WebFetch, Delegate remain removable
  - Scratchpad tools (ScratchpadWrite/Read/List) remain removable

- **Delegation Tool Names**: Now use proper PascalCase for multi-word agent names
  - `slack_agent` → `WorkWithSlackAgent` (was `WorkWithSlack_agent`)
  - `web_scraper` → `WorkWithWebScraper` (was `WorkWithWeb_scraper`)
  - Single-word names unchanged: `backend` → `WorkWithBackend`

- **Tool Activation**: Moved to `around_llm_request` hook (before each LLM request)
  - Ensures tools match current skill state
  - Critical: RubyLLM requires symbol keys for tool lookup

- **ToolConfigurator**: Updated to register tools in registry instead of direct `add_tool()`
  - Tracks tool source (builtin, delegation, MCP, plugin)
  - Stores base_instance for skill permission override

- **AgentInitializer**: Updated to 6-pass initialization
  - Pass 6 activates tools after all plugins have registered
  - Ensures LoadSkill tool is available when activation happens

### Removed

- **`chat.mark_tools_immutable(*tool_names)`**: Tools now declare `removable false` themselves
- **`chat.remove_mutable_tools()`**: Use `chat.clear_skill()` instead

### Fixed

- **Symbol Key Compatibility**: Tools now stored with symbol keys as required by RubyLLM
- **Tool Execution**: Tool instances properly activated before LLM requests
- **Event Emission**: tool_result events now fire correctly

## [2.6.2] - 2025-12-10

### Added

- **Anthropic Provider Base URL Configuration**: Custom Anthropic endpoints now properly configured
  - Added `anthropic_api_base` configuration for custom Anthropic API endpoints
  - Added `anthropic_api_key` passthrough from `SwarmSDK.config`
  - Enables use of Anthropic-compatible proxies and custom deployments
  - **Files**: `lib/swarm_sdk/agent/chat_helpers/llm_configuration.rb`

### Dependencies

- Updated `ruby_llm_swarm` to `~> 1.9.6`

## [2.6.0] - 2025-12-04

### Added

- **Execution Timeouts**: External timeout enforcement using Async's `task.with_timeout()` with `Async::Barrier` for child task management
  - **`execution_timeout`** (swarm-level): Maximum wall-clock time for entire `swarm.execute()` call
  - **`turn_timeout`** (agent-level): Maximum time for single `agent.ask()` call (LLM + all tools)
  - **Default**: Both default to `1800` seconds (30 minutes)
  - **Configurable globally**: `SwarmSDK.config.default_execution_timeout`, `SwarmSDK.config.default_turn_timeout`
  - **Per-swarm/agent overrides**: Via DSL and YAML configuration
  - **Validation**: Zero and negative values rejected with `ConfigurationError`
  - **Interrupts immediately**: Uses `Async::Barrier` to stop ALL child tasks (tool executions, delegations) when timeout fires
  - **Why barrier needed**: SwarmSDK uses `max_concurrent_tools: 10` by default, making RubyLLM spawn child tasks for tool execution. Without `barrier.stop`, child tasks continue after timeout.
  - **Cleanup guaranteed**: `ensure` blocks always run after timeout, barrier cleanup ensures no zombie tasks
  - **New exception classes**: `TimeoutError`, `ExecutionTimeoutError`, `TurnTimeoutError`
  - **New events**: `execution_timeout` and `turn_timeout` for monitoring
  - **Turn timeout behavior**: Returns error message (not exception) so delegating agents can handle gracefully: "Error: Request timed out after Xs..."
  - **Files**: `lib/swarm_sdk.rb`, `lib/swarm_sdk/swarm/executor.rb`, `lib/swarm_sdk/agent/chat.rb`
  - **Documentation**: `plans/023-execution-timeouts.md`, `decisions/2025-12-02-002-external-timeout-enforcement.md`

### Changed - BREAKING

- **`timeout` configuration renamed to `request_timeout`**: Clarifies scope (LLM HTTP request only)
  - **Ruby DSL**: `timeout()` → `request_timeout()`
  - **Ruby DSL**: `timeout_set?()` → `request_timeout_set?()`
  - **YAML**: `timeout:` → `request_timeout:`
  - **Agent::Definition**: `.timeout` → `.request_timeout`
  - **Why**: The old name was ambiguous - it only controlled HTTP request timeout, not the entire agent turn
  - **Migration**: Simple search and replace (`timeout` → `request_timeout` in agent configs)
  - **Note**: `SwarmSDK.config.agent_request_timeout` unchanged (already used correct name)
  - **Files**: All builder classes, `Agent::Definition`, YAML parser/translator
  - **Tests**: Updated 14 tests across 9 test files

## [2.5.5] - 2025-12-03

### Changed - BREAKING

- **Smart LLM Retry Strategy**: Redesigned retry logic to differentiate between recoverable and non-recoverable errors
  - **Retry defaults reduced**: `max_retries` from 10 to 3, `delay` increased from 10s to 15s
  - **Non-retryable client errors (4xx)**: Now return error messages immediately instead of retrying
    - 400 Bad Request (after orphan recovery attempt)
    - 401 Unauthorized (invalid API key)
    - 402 Payment Required (billing issue)
    - 403 Forbidden (permission denied)
    - 422 Unprocessable Entity (invalid parameters)
    - Other 4xx errors
  - **Retryable server errors (5xx)**: Retry up to 3 times at SDK level
    - Note: RubyLLM already retries 3 times internally with exponential backoff
    - Total attempts: 6 (3 RubyLLM + 3 SDK)
    - Affected: 429 Rate Limit, 500 Server Error, 502-503 Service Unavailable, 529 Overloaded
  - **Orphan tool call recovery**: Preserved for 400 Bad Request errors (existing behavior)
  - **Error message format**: Non-retryable errors return as formatted assistant messages for natural delegation flow
  - **Performance improvement**:
    - Client error failures: 100s faster (0s vs 100s with old logic)
    - Server error failures: 55s faster (45.7s vs 100.7s)
    - API call reduction: 90% fewer wasted calls for client errors (1 vs 10 attempts)
  - **Files**: `lib/swarm_sdk/agent/chat.rb`
  - **Tests**: Updated `test/swarm_sdk/agent/chat_test.rb` to reflect new behavior
  - **Documentation**: `decisions/2025-12-03-004-llm-retry-strategy.md`

### Added

- **New event type**: `llm_request_failed` - Emitted for non-retryable errors
  - Includes: error_type, error_class, error_message, status_code, retryable flag
  - Useful for monitoring authentication failures, billing issues, and other non-transient problems
  - Example:
    ```ruby
    {
      type: "llm_request_failed",
      agent: :backend,
      error_type: "Unauthorized",
      error_class: "RubyLLM::UnauthorizedError",
      error_message: "Invalid API key",
      status_code: 401,
      retryable: false
    }
    ```

### Fixed

- **Critical rescue block order bug**: Generic `RubyLLM::Error` catch-all was intercepting server errors before specific rescue blocks
  - **Impact**: 500 errors were incorrectly treated as non-retryable and returned as messages
  - **Fix**: Moved server error rescue blocks before generic catch-all
  - **Result**: Server errors now retry correctly (3 attempts) then raise

## [2.5.4]

### Fixed

- **MCP Non-Compliant Server Compatibility** - Added support for MCP servers that return HTTP 400 instead of 405
  - **Issue**: Some MCP servers (e.g., Firecrawl) return `400 Bad Request` when rejecting SSE streams, causing swarm execution to fail
  - **MCP Spec**: Per MCP HTTP+SSE specification, servers should return `405 Method Not Allowed` for unsupported SSE
  - **Non-compliant behavior**: Firecrawl and other servers incorrectly return `400 Bad Request`
  - **Previous behavior**: `ruby_llm-mcp` logged ERROR and raised TransportError exception, stopping execution
  - **Fix**: Using local `ruby_llm-mcp` fork with modified `StreamableHTTP` transport:
    - Treats HTTP 400 the same as 405 (graceful degradation)
    - Logs INFO-level message explaining non-compliant behavior
    - Returns `nil` to continue execution without SSE streaming
    - No ERROR logs, clean execution
  - **Configuration**: Both `type: http` and `type: streamable` work correctly (are equivalent)
  - **Impact**: Swarms can now use non-compliant MCP servers without errors
  - **Files**: `Gemfile` (added local path to `ruby_llm-mcp`)
  - **Documentation**: `decisions/2025-12-03-003-mcp-400-handling.md`

## [2.5.3]

### Fixed

- **Context Window String Coercion Bug**: Fixed `NoMethodError: undefined method 'zero?' for String` when `context_window` is a quoted string in YAML
  - **Issue**: YAML configs with `context_window: '1000000'` (string) caused error when calling `context_usage_percentage`
  - **Root cause**: `TokenTracking#context_usage_percentage` called `.zero?` on string value from YAML
  - **Fix**: Added `coerce_to_integer` helper in `Agent::Definition` to convert string numeric values to integers
  - **Impact**: String context_window values from YAML now properly coerced during agent initialization
  - **Files**: `lib/swarm_sdk/agent/definition.rb`
  - **Tests**: 4 comprehensive tests covering string coercion, integer preservation, nil handling, and regression protection

### Added

- **Orphan Tool Call Recovery**: Automatic recovery from malformed conversation history on 400 Bad Request errors
  - **What are orphan tool calls?**: Assistant messages with `tool_use` blocks that lack corresponding `tool_result` messages
  - **Causes**: Tool execution interruption, session state restoration issues, network disruptions during tool execution
  - **Automatic detection**: Scans message history when receiving tool-related 400 errors from API
  - **Smart pruning**: Removes orphan `tool_calls` while preserving assistant message content
  - **System reminder**: Informs agent about interrupted tool calls with details (tool name, arguments)
  - **Zero-cost retry**: Pruning and retry happen immediately without counting toward retry limit
  - **Error patterns detected**:
    - `"tool_use block must have corresponding tool_result"`
    - `"tool_use_id not found"`
    - `"must immediately follow"`
  - **Behavior**:
    - Partial orphans: Keeps completed tool calls, removes only orphans
    - Empty messages: Removes assistant messages that become empty after pruning
    - Content preservation: Keeps assistant message content, only removes `tool_calls`
  - **System reminder format**:
    ```
    <system-reminder>
    The following tool calls were interrupted and removed from conversation history:
    - Read(file_path: "/important/file.rb")
    - Write(file_path: "/output.txt", content: "Hello...")
    These tools were never executed. If you still need their results, please run them again.
    </system-reminder>
    ```
  - **Logging**: Emits `orphan_tool_calls_pruned` event with count and error details
  - **Test coverage**: 5 comprehensive integration tests through public API
  - **Files**: `lib/swarm_sdk/agent/chat.rb` (+150 lines), `test/swarm_sdk/agent/chat_test.rb` (+200 lines)
  - **Documentation**: Updated `lib/swarm_sdk/agent/RETRY_LOGIC.md` with complete recovery guide

### Fixed

- **Ephemeral Content Timing Bug**: Fixed system reminders not being injected on retry after orphan tool call pruning
  - **Issue**: `prepare_for_llm` was called once before retry loop, so retries used stale message state
  - **Impact**: System reminders added after pruning weren't included in retry requests
  - **Root cause**: Prepared messages calculated before `call_llm_with_retry`, reused on all retry attempts
  - **Fix**: Moved `prepare_for_llm(@llm_chat.messages)` inside retry block for fresh calculation on each attempt
  - **Result**: Ephemeral content (system reminders) now correctly recalculated after message pruning
  - **Side effect**: All retries now get fresh ephemeral content (correct behavior, negligible performance impact)
  - **Files**: `lib/swarm_sdk/agent/chat.rb:647-662`

## [2.5.2] - 2025-11-28

### Added

- **LLM-Readable Transcript Generation**: New `result.transcript()` method for generating formatted conversation transcripts
  - **`result.transcript`**: Returns full transcript from all agents in LLM-consumable format
  - **Agent filtering**: `result.transcript(:backend, :database)` filters to specific agents
  - **Options**:
    - `include_tool_results: true` - Include/exclude tool execution results (default: true)
    - `include_thinking: false` - Include/exclude agent_step reasoning (default: false)
  - **Format**: Human/LLM-readable with clear prefixes (USER:, AGENT [name]:, TOOL, RESULT, DELEGATE)
  - **Truncation**: Automatic truncation of long tool results (500 chars) and arguments (200 chars)
  - **Use cases**: Memory creation, reflection, debugging, conversation analysis, passing context to other agents
  - **Example**:
    ```ruby
    result = swarm.execute("Build authentication")

    # Full transcript
    puts result.transcript
    # => USER: Build authentication
    #    TOOL [backend] → Read({"path":"auth.rb"})
    #    RESULT [Read]: def authenticate...
    #    AGENT [backend]: I've implemented authentication.

    # Filter to specific agents
    puts result.transcript(:backend, :database)

    # Include thinking steps
    puts result.transcript(include_thinking: true)
    ```
  - **Implementation**: New `TranscriptBuilder` class for flexible log formatting
  - **Files**: `lib/swarm_sdk/transcript_builder.rb`, `lib/swarm_sdk/result.rb`, `lib/swarm_sdk/swarm/logging_callbacks.rb`
  - **Tests**: 22 comprehensive tests covering all formatting scenarios

## [2.5.1]

### Dependencies

- Updated `ruby_llm_swarm-mcp` to `~> 0.8.1`

## [2.5.0]

### Added

- **Custom Tool Registration**: Simple API for registering custom tools without creating full plugins
  - **`SwarmSDK.register_tool(ToolClass)`**: Register with inferred name (e.g., `WeatherTool` → `:Weather`)
  - **`SwarmSDK.register_tool(:Name, ToolClass)`**: Register with explicit name
  - **`SwarmSDK.custom_tool_registered?(:Name)`**: Check if tool is registered
  - **`SwarmSDK.custom_tools`**: List all registered custom tool names
  - **`SwarmSDK.unregister_tool(:Name)`**: Remove a registered tool
  - **`SwarmSDK.clear_custom_tools!`**: Clear all registered tools (useful for testing)
  - **Tool lookup order**: Plugin tools → Custom tools → Built-in tools
  - **Context support**: Tools can declare `creation_requirements` for agent context (`:agent_name`, `:directory`)
  - **Name consistency**: `NamedToolWrapper` ensures registered name is used for tool lookup
  - **Validation**: Prevents overriding built-in tools or plugin tools
  - **Use case**: Simple, stateless tools that don't need plugin lifecycle hooks or storage
  - **Example**:
    ```ruby
    class WeatherTool < RubyLLM::Tool
      description "Get weather for a city"
      param :city, type: "string", required: true

      def execute(city:)
        "Weather in #{city}: Sunny"
      end
    end

    SwarmSDK.register_tool(WeatherTool)

    SwarmSDK.build do
      name "Assistant"
      lead :helper

      agent :helper do
        model "claude-sonnet-4"
        description "Weather assistant"
        system_prompt "You help with weather"
        tools :Weather  # Use the registered tool
      end
    end
    ```
  - **Files**: `lib/swarm_sdk/custom_tool_registry.rb`, `lib/swarm_sdk.rb`, `lib/swarm_sdk/swarm/tool_configurator.rb`
  - **Tests**: 32 comprehensive tests (unit + integration)

### Changed

- **BREAKING: Plugin API method renamed**: `storage_enabled?` → `memory_configured?` in Plugin base class
  - **Rationale**: "memory" is the user-facing concept, "storage" is internal implementation detail
  - **Better semantics**: "Is memory configured?" vs "Is storage enabled?"
  - **No backward compatibility**: `storage_enabled?` method removed entirely (breaking change)
  - **Impact**: Custom plugins implementing `storage_enabled?` must rename to `memory_configured?`
  - **Migration**: Update plugin classes to implement `memory_configured?` instead of `storage_enabled?`
  - **Files**: `lib/swarm_sdk/plugin.rb:142-148`
  - **Updated callers**:
    - `lib/swarm_sdk/swarm/agent_initializer.rb:572`
    - `lib/swarm_sdk/agent/system_prompt_builder.rb:151`
    - `lib/swarm_sdk/swarm/tool_configurator.rb:270`
  - **Tests**: All plugin-related tests updated

## [2.4.6]
- Use a fork of ruby_llm-mcp that requires ruby_llm_swarm instead of ruby_llm

## [2.4.5]

### Fixed

- **Context Window Tracking Bug**: Fixed model lookup using wrong source for context window data
  - **Issue**: Changes to `models.json` had no effect on context window tracking - SDK always returned 0%
  - **Root cause**: `fetch_real_model_info` was using `RubyLLM.models.find()` instead of `SwarmSDK::Models.find()`
  - **Fix**: Changed model lookup to use `SwarmSDK::Models.find()` first, falling back to `RubyLLM.models.find()`
  - **Impact**: Context window percentage now correctly calculated from SwarmSDK's models.json
  - **Files**: `lib/swarm_sdk/agent/chat_helpers/llm_configuration.rb`

### Added

- **Per-Agent Context Breakdown**: Real-time and historical context usage metrics per agent
  - **`Swarm#context_breakdown`**: Returns live context metrics for all agents including:
    - Token counts: `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`, `cache_creation_tokens`, `effective_input_tokens`
    - Context limits: `context_limit`, `usage_percentage`, `tokens_remaining`
    - Cost metrics: `input_cost`, `output_cost`, `total_cost`
  - **`Result#per_agent_usage`**: Extracts per-agent usage from execution logs (for historical analysis)
  - **`swarm_stop` event enhancement**: Now includes `per_agent_usage` field with complete breakdown
  - **Use cases**: Monitor token consumption, track costs per agent, identify context-heavy agents
  - **Example**:
    ```ruby
    breakdown = swarm.context_breakdown
    breakdown[:backend]
    # => {
    #   input_tokens: 15000,
    #   output_tokens: 5000,
    #   total_tokens: 20000,
    #   cached_tokens: 2000,
    #   context_limit: 200000,
    #   usage_percentage: 10.0,
    #   tokens_remaining: 180000,
    #   input_cost: 0.045,
    #   output_cost: 0.075,
    #   total_cost: 0.12
    # }
    ```
  - **Files**: `lib/swarm_sdk/swarm.rb`, `lib/swarm_sdk/result.rb`, `lib/swarm_sdk/swarm/hook_triggers.rb`, `lib/swarm_sdk/swarm/logging_callbacks.rb`

- **Cumulative Cost Tracking in TokenTracking**: New methods for calculating conversation costs
  - **`cumulative_input_cost`**: Calculate total input cost based on tokens and model pricing
  - **`cumulative_output_cost`**: Calculate total output cost based on tokens and model pricing
  - **`cumulative_total_cost`**: Sum of input and output costs
  - **Pricing source**: Uses `@real_model_info.pricing` from SwarmSDK's models.json
  - **Files**: `lib/swarm_sdk/agent/chat_helpers/token_tracking.rb`

- **ModelInfo Class**: Wrapper class for model data with method access
  - **`SwarmSDK::Models::ModelInfo`**: Replaces raw Hash returns from `Models.find()`
  - **Attributes**: `id`, `name`, `provider`, `family`, `context_window`, `max_output_tokens`, `knowledge_cutoff`, `modalities`, `capabilities`, `pricing`, `metadata`
  - **Files**: `lib/swarm_sdk/models.rb`

### Tests

- **28 new tests** covering:
  - `TokenTracking` cost methods (24 tests): context_limit, cumulative costs, pricing edge cases
  - `Swarm#context_breakdown` (5 tests): structure, metrics, delegation instances, lazy initialization

## [2.4.4]

### Added

- **Environment Variable Interpolation Control**: New `env_interpolation` setting to disable YAML variable interpolation
  - **Global config**: `SwarmSDK.configure { |c| c.env_interpolation = false }`
  - **Environment variable**: `SWARM_SDK_ENV_INTERPOLATION=false`
  - **Per-load override**: `SwarmSDK.load(yaml, env_interpolation: false)` or `SwarmSDK.load_file(path, env_interpolation: false)`
  - **Priority order**: per-load parameter > global config > environment variable > default (true)
  - **Use cases**:
    - Testing YAML files without setting environment variables
    - Loading configs where `${...}` syntax should be preserved literally
    - Security: preventing accidental environment variable exposure
  - **Example**:
    ```ruby
    # Disable globally
    SwarmSDK.configure do |config|
      config.env_interpolation = false
    end

    # Disable for specific load
    swarm = SwarmSDK.load_file("config.yml", env_interpolation: false)
    ```
  - **Files**: `lib/swarm_sdk/config.rb`, `lib/swarm_sdk/configuration.rb`, `lib/swarm_sdk/configuration/parser.rb`, `lib/swarm_sdk.rb`
  - **Tests**: Comprehensive tests in `config_test.rb` and `configuration_test.rb`

## [2.4.3]

### Added

- **Global Agent Registry**: Declare agents in separate files and reference them by name across swarms
  - **`SwarmSDK.agent(:name) { ... }`**: Register agents globally for reuse across multiple swarms
  - **`SwarmSDK.clear_agent_registry!`**: Clear all registrations (useful for testing)
  - **Registry lookup in builders**: `agent :name` (no block) fetches from global registry
  - **Registry + overrides**: `agent :name do ... end` applies registry config then override block
  - **Duplicate registration error**: Raises `ArgumentError` if registering same name twice
  - **Workflow node auto-resolution**: Agents referenced in nodes automatically resolve from registry
    - Checks workflow-level definitions first, then falls back to global registry
    - Includes delegation targets (`delegates_to`) in auto-resolution
  - **Best practice**: Don't set `delegates_to` in registry—delegation is swarm-specific. Set it as an override in each swarm.
  - **Use case**: Define agents once in separate files, compose into multiple swarms without duplication
  - **Example**:
    ```ruby
    # agents/backend.rb
    SwarmSDK.agent :backend do
      model "claude-sonnet-4"
      description "Backend developer"
      tools :Read, :Edit, :Bash
    end

    # swarm.rb
    SwarmSDK.build do
      name "Dev Team"
      lead :backend
      agent :backend  # Pulls from registry
    end

    # workflow.rb - agents auto-resolve in nodes
    SwarmSDK.workflow do
      name "Pipeline"
      start_node :build
      node(:build) { agent(:backend) }  # Auto-resolved from registry
    end
    ```
  - **Files**: `lib/swarm_sdk/agent_registry.rb`, `lib/swarm_sdk.rb`, `lib/swarm_sdk/builders/base_builder.rb`, `lib/swarm_sdk/workflow/builder.rb`
  - **Tests**: 32 comprehensive tests in `test/swarm_sdk/agent_registry_test.rb`

## [2.4.2]

### Fixed

- **Duplicate event emission bug**: Fixed agent_stop and agent_step events being emitted twice
  - Root cause: `setup_logging` was being called twice during agent initialization
  - First call in `agent_initializer.rb` when `LogStream.emitter` was set
  - Second call in `emit_retroactive_agent_start_events` via `setup_logging_for_all_agents`
  - Fix: Made `ContextTracker#setup_logging` idempotent with `@logging_setup` guard
  - Prevents duplicate callback registration on `on_end_message`, `on_tool_result`, and `on_tool_call`

### Added

- **Event deduplication tests**: Comprehensive test suite to prevent regression
  - `test_agent_stop_event_not_duplicated` - Ensures agent_stop emitted exactly once
  - `test_agent_step_event_not_duplicated` - Ensures agent_step emitted exactly once per tool response
  - `test_tool_call_event_not_duplicated` - Ensures tool_call emitted exactly once per invocation
  - `test_tool_result_event_not_duplicated` - Ensures tool_result emitted exactly once
  - `test_setup_logging_idempotency` - Verifies idempotent behavior across multiple executions
  - `test_comprehensive_event_counts_*` - Validates exact event counts for various scenarios

### Dependencies

- Updated `ruby_llm_swarm` to `~> 1.9.5`
- Added `openssl` (`~> 3.3.2`) dependency

## [2.4.1]
- Fix gemspec issues

## [2.4.0]

### Breaking Changes

- **Centralized Configuration System**: Unified all configuration into `SwarmSDK::Config`
  - **New API**: `SwarmSDK.config` replaces `SwarmSDK.settings`
  - **Removed**: `SwarmSDK::Settings` class removed entirely
  - **Removed**: `SwarmSDK.settings` method removed
  - **Removed**: `SwarmSDK.reset_settings!` → use `SwarmSDK.reset_config!`
  - **Removed**: Tool constants (DEFAULT_TIMEOUT_MS, MAX_OUTPUT_LENGTH, etc.)
  - **API key proxying**: All API keys automatically proxy to `RubyLLM.config`
  - **Override all defaults**: Every constant in Defaults module can now be overridden at runtime
  - **Priority**: explicit value → ENV variable → Defaults module constant
  - **Lazy ENV loading**: Thread-safe with double-check locking
  - **Migration**:
    - `SwarmSDK.settings.allow_filesystem_tools` → `SwarmSDK.config.allow_filesystem_tools`
    - `SwarmSDK.reset_settings!` → `SwarmSDK.reset_config!`
    - Tool constants → `SwarmSDK.config.*` methods (e.g., `SwarmSDK.config.bash_command_timeout`)

### Fixed

- **Base URL Configuration Bug**: Custom provider contexts now properly use configured API keys
  - Previously: `configure_provider_base_url` read ENV directly, ignoring `RubyLLM.config`
  - Now: Uses `SwarmSDK.config.openai_api_key` and other configured values
  - Better error messages when API keys are missing for non-local endpoints

## [2.3.0]

### Breaking Changes

- **Agent::Chat Abstraction Layer**: Refactored Agent::Chat from inheritance to composition with RubyLLM::Chat
  - **Removed direct access**: SDK consumers can no longer access `.tools`, `.messages`, or `.model` directly
  - **New abstraction methods**: SwarmSDK-specific API that hides RubyLLM internals
    - `has_tool?(name)` - Check if tool exists by name (symbol or string)
    - `tool_names` - Get array of tool names (symbols)
    - `model_id` - Get model identifier string
    - `model_provider` - Get model provider string
    - `message_count` - Get number of messages in conversation
    - `has_user_message?` - Check if conversation has any user messages
    - `last_assistant_message` - Get most recent assistant message
    - `take_snapshot` - Serialize conversation for persistence
    - `restore_snapshot(data)` - Restore conversation from serialized data
  - **Internal access methods**: For helper modules that need direct access
    - `internal_messages` - Direct array of RubyLLM messages (for internal use only)
    - `internal_tools` - Direct hash of tool instances (for internal use only)
    - `internal_model` - Direct RubyLLM model object (for internal use only)
  - **Migration**:
    - `chat.tools.key?(:Read)` → `chat.has_tool?(:Read)`
    - `chat.tools.keys` → `chat.tool_names`
    - `chat.model.id` → `chat.model_id`
    - `chat.model.provider` → `chat.model_provider`
    - `chat.messages.count` → `chat.message_count`
    - `chat.messages` (for internal modules) → `chat.internal_messages`
  - **Improved encapsulation**: Prevents tight coupling to RubyLLM internals, making future LLM library changes easier
  - **Files affected**:
    - `lib/swarm_sdk/agent/chat.rb` - Core abstraction implementation
    - `lib/swarm_sdk/swarm.rb` - Uses `tool_names` instead of `tools.keys`
    - `lib/swarm_sdk/state_snapshot.rb` - Uses `internal_messages`
    - `lib/swarm_sdk/state_restorer.rb` - Uses `internal_messages`
    - `lib/swarm_sdk/context_compactor.rb` - Uses `internal_messages`
    - `lib/swarm_sdk/agent/chat/hook_integration.rb` - Uses abstraction methods
    - `lib/swarm_sdk/agent/chat/system_reminder_injector.rb` - Uses abstraction methods
    - `lib/swarm_sdk/agent/chat/context_tracker.rb` - Uses `model_id`

- **MAJOR REFACTORING**: Separated Swarm and Workflow into distinct, clear APIs
  - `SwarmSDK.build` now ONLY returns `Swarm` (simple multi-agent collaboration)
  - New `SwarmSDK.workflow` API for multi-stage workflows (returns `Workflow`)
  - `NodeOrchestrator` class renamed to `Workflow` (clearer naming)
  - Attempting to use nodes in `SwarmSDK.build` now raises `ConfigurationError`
  - Snapshot version bumped to 2.0.0 (old snapshots incompatible)
  - Snapshot structure changed: `swarm:` key renamed to `metadata:`

- **YAML Configuration**: Explicit type keys for Swarm vs Workflow
  - `swarm:` key now ONLY for Swarm configurations (requires `lead:`, cannot have `nodes:`)
  - New `workflow:` key for Workflow configurations (requires `start_node:` and `nodes:`)
  - Cannot have both `swarm:` and `workflow:` keys in same file
  - Same `SwarmSDK.load_file` API works for both types (auto-detects from root key)

### Added

- New `SwarmSDK.workflow` DSL for building multi-stage workflows
- **YAML `workflow:` key support**: Explicit root key for workflow configurations
  - Clearer separation between Swarm and Workflow in YAML files
  - Configuration class with proper separation of concerns (type detection, validation, loading)
  - Validates type-specific requirements (e.g., `swarm:` cannot have `nodes:`)
- Three new concern modules for shared functionality:
  - `Concerns::Snapshotable` - Common snapshot/restore interface
  - `Concerns::Validatable` - Common validation interface
  - `Concerns::Cleanupable` - Common cleanup interface
- `Builders::BaseBuilder` - Shared DSL logic for both Swarm and Workflow builders
- Both `Swarm` and `Workflow` now implement common interface methods:
  - `primary_agents` - Access to primary agent instances
  - `delegation_instances_hash` - Access to delegation instances

### Changed

- `Workflow` (formerly `NodeOrchestrator`) internal structure simplified to match `Swarm`:
  - Replaced `@agent_instance_cache = { primary: {}, delegations: {} }`
  - With `@agents = {}` and `@delegation_instances = {}`
- `Swarm::Builder` dramatically simplified: 784 lines → 208 lines (73% reduction)
- `StateSnapshot` and `StateRestorer` no longer use type checking - rely on interface methods
- `SnapshotFromEvents` updated to generate v2.0.0 snapshots with new structure
- Module namespace: `Node::` renamed to `Workflow::`
  - `Node::Builder` → `Workflow::NodeBuilder`
  - `Node::AgentConfig` → `Workflow::AgentConfig`
  - `Node::TransformerExecutor` → `Workflow::TransformerExecutor`

### Removed

- Dual-return-type pattern from `SwarmSDK.build` (no longer returns `NodeOrchestrator`)
- ~600 lines of duplicated code across Swarm and NodeOrchestrator
- Complex type-checking logic in StateSnapshot and StateRestorer

### Migration Guide

**For vanilla swarm users (no nodes):** No changes needed! Your code works as-is.

**For workflow users (using Ruby DSL):** Change `SwarmSDK.build` to `SwarmSDK.workflow`:

```ruby
# Before
SwarmSDK.build do
  node :planning { ... }
end

# After
SwarmSDK.workflow do
  node :planning { ... }
end
```

**For YAML workflow users:** Change `swarm:` key to `workflow:`:

```yaml
# Before
version: 2
swarm:
  name: "Pipeline"
  start_node: planning
  agents: { ... }
  nodes: { ... }

# After
version: 2
workflow:
  name: "Pipeline"
  start_node: planning
  agents: { ... }
  nodes: { ... }
```

**For event-sourcing users:** No changes needed! `SnapshotFromEvents.reconstruct(events)` automatically generates v2.0.0 snapshots.

**For snapshot storage users:** Old snapshots (v1.0.0) won't restore. Create new snapshots or convert:
```ruby
old[:version] = "2.0.0"
old[:metadata] = old.delete(:swarm)
```

### Added

- **Non-Blocking Execution with Cancellation Support**: Optional `wait` parameter enables task cancellation
  - **`wait: true` (default)**: Maintains backward-compatible blocking behavior, returns `Result`
  - **`wait: false`**: Returns `Async::Task` immediately for non-blocking execution
  - **`task.stop`**: Cancels execution at next fiber yield point (HTTP I/O, tool boundaries)
  - **Cooperative cancellation**: Stops when fiber yields, not immediate for synchronous operations
  - **Proper cleanup**: MCP clients, fiber storage, and logging cleaned in task's ensure block
  - **Cleanup on cancellation**: Ensure blocks execute when task stopped via `Async::Stop` exception
  - **`task.wait` returns nil**: Cancelled tasks return `nil` from `wait` method
  - **Execution flow**: Reprompting loop and all cleanup moved inside Async block
  - **Parent cleanup**: Fiber storage cleaned after `task.wait` when `wait: true`
  - **Examples**:
    - Blocking: `result = swarm.execute("Build auth")` (current behavior)
    - Non-blocking: `task = swarm.execute("Build auth", wait: false)` then `task.stop`
  - **Files**: `lib/swarm_sdk/swarm.rb` (major refactor of execute method)
  - **Tests**: 9 comprehensive tests in `test/swarm_sdk/execute_wait_parameter_test.rb`

- **Delegation Result Event Reconstruction**: Snapshot/restore now handles delegation events properly
  - **`delegation_result` event support**: EventsToMessages reconstructs tool result messages from delegations
  - **Proper conversation restoration**: Delegations correctly reconstructed from event logs
  - **Snapshot compatibility**: Enables complete state restoration including delegation history
  - **Files**: `lib/swarm_sdk/events_to_messages.rb`

- **User Prompt Source Tracking**: `user_prompt` events now include source information to distinguish user interactions from delegations
  - **`source` field**: Indicates origin of prompt - `"user"` (direct user interaction) or `"delegation"` (from delegation tool)
  - **Event filtering**: Enables filtering user prompts by source in logs and analytics
  - **Delegation tracking**: Identify which prompts originated from agent delegations vs direct user input
  - **Hook context**: Source information available in user_prompt hooks via `context.metadata[:source]`
  - **Implementation**: Source passed through `ask()` method options, extracted in `trigger_user_prompt()`
  - **Default behavior**: All prompts default to `source: "user"` for backward compatibility
  - **Files**: `lib/swarm_sdk/agent/chat/hook_integration.rb`, `lib/swarm_sdk/tools/delegate.rb`, `lib/swarm_sdk/swarm.rb`
  - **Example**: `{ type: "user_prompt", agent: "backend", source: "delegation", ... }`

- **Safe Return Statements in Node Transformers**: Input and output transformers now support `return` statements for natural control flow
  - **Automatic lambda conversion**: Blocks passed to `input {}` and `output {}` are automatically converted to lambdas via `ProcHelpers.to_lambda`
  - **Safe early exits**: Use `return` for early exits without risking program termination
  - **Natural control flow**: Write intuitive conditional logic with standard Ruby `return` keyword
  - **Examples**: `return ctx.skip_execution(content: "cached") if cached?`, `return ctx.halt_workflow(content: "error") if invalid?`
  - **Implementation**: Converts Proc to UnboundMethod via `define_method`, then wraps in lambda where `return` only exits the method
  - **Backward compatible**: Existing code without `return` statements continues to work unchanged
  - **Files**: `lib/swarm_sdk/proc_helpers.rb`, `lib/swarm_sdk/node/builder.rb`
  - **Tests**: 8 comprehensive tests in `test/swarm_sdk/proc_helpers_test.rb` covering closures, keyword args, block args, and multiple return paths

- **Per-Node Tool Overrides**: Agents can now have different tool sets in different nodes
  - **Node-specific tools**: Override agent's global tool configuration on a per-node basis
  - **Fluent syntax**: Chain with delegation: `agent(:backend).delegates_to(:tester).tools(:Read, :Edit, :Write)`
  - **Use case**: Restrict tools for specific workflow stages (e.g., planning node with thinking tools only, execution node with file tools)
  - **Example**: `agent(:planner).tools(:Think, :Read)` in planning node, `agent(:planner).tools(:Write, :Edit, :Bash)` in implementation node
  - **Implementation**: New `tools(*tool_names)` method on `AgentConfig`, stored in node configuration as tool override
  - **Backward compatible**: Omit `.tools()` to use agent's global tool configuration
  - **Files**: `lib/swarm_sdk/workflow/agent_config.rb`, `lib/swarm_sdk/workflow/node_builder.rb`, `lib/swarm_sdk/workflow.rb`

### Changed

- **BREAKING: Delegation Tool Rebranding**: Delegation tools renamed to emphasize collaboration over task delegation
  - **Tool naming**: `DelegateTaskToBackend` → `WorkWithBackend`
  - **Tool parameter**: `task:` → `message:` (more flexible, supports questions and collaboration)
  - **Tool description**: Now emphasizes working with agents, not just delegating tasks
  - **Configurable prefix**: Added `TOOL_NAME_PREFIX` constant for easy customization
  - **Migration**: Update code/tests using `DelegateTaskTo*` to use `WorkWith*`
  - **Parameter migration**: Change `task:` parameter to `message:` in delegation tool calls
  - **Rationale**: Better reflects collaborative agent relationships and flexible communication patterns
  - **Files affected**: `lib/swarm_sdk/tools/delegate.rb`, `lib/swarm_sdk/agent/chat/context_tracker.rb`, `lib/swarm_sdk/swarm/agent_initializer.rb`, `lib/swarm_cli/interactive_repl.rb`
  - **Tests updated**: All delegation tests updated to use new naming (18 files)

### Fixed

- **MCP Configuration for Non-OAuth Servers**: Fixed errors when configuring MCP servers without OAuth
  - **Issue**: OAuth field was included in streamable config even when not configured, causing errors
  - **Fix**: Removed `oauth` field from streamable config hash
  - **Additional fix**: Only include `rate_limit` if explicitly configured (avoid nil values)
  - **Impact**: MCP servers without OAuth now configure correctly without errors
  - **Files**: `lib/swarm_sdk/swarm/mcp_configurator.rb`

## [2.2.0] - 2025-11-06

### Fixed

- **Snapshot Restoration Critical Bugs**: Fixed two critical bugs preventing proper state restoration
  - **Bug 1 - Delegation Instance Validation**: Delegation instances incorrectly rejected during restoration
    - **Issue**: `bob@jarvis` delegation failed validation even when both agents existed
    - **Root cause**: Validation checked if base agent (`bob`) existed as primary agent in snapshot, but bob only appeared as delegation
    - **Fix**: Changed validation to check if base agent exists in **current configuration** instead of snapshot
    - **Impact**: Delegation instances can now be restored correctly from snapshots and events
  - **Bug 2 - System Prompt Ordering**: System prompts applied then immediately removed
    - **Issue**: `with_instructions()` adds system message, but `messages.clear` was called after, removing it
    - **Root cause**: Wrong order of operations - system prompt added before clearing messages
    - **Fix**: Clear messages first, then add system prompt, then restore conversation
    - **Impact**: System prompts now correctly preserved during restoration for all agents
  - **Result**: Event sourcing fully functional, delegation workflows restore correctly
  - **Files**: `lib/swarm_sdk/state_restorer.rb` - Lines 140-141, 210-225, 340-356

- **Event Timestamp Precision**: Microsecond-precision timestamps for correct event ordering
  - **Issue**: Events emitted rapidly within same second had identical timestamps, causing arbitrary sort order
  - **Impact**: Message reconstruction from events produced incorrect conversation order (tool results before tool calls)
  - **Root cause**: `Time.now.utc.iso8601` defaults to second precision, events within same second indistinguishable
  - **Fix**: Use `Time.now.utc.iso8601(6)` for microsecond precision (e.g., `2025-11-05T19:10:58.123456Z`)
  - **Files**: `log_stream.rb:54`, `log_collector.rb:65`
  - **Result**: Events now sort correctly even when emitted microseconds apart
  - **Critical for**: Snapshot reconstruction, delegation conversations, rapid tool executions

- **Rails/Puma Event Loss in Multi-Threaded Environments**: Complete fix for event streaming in production
  - **Issue**: Events lost on subsequent requests when using `restore()` before `execute()` in Rails/Puma
  - **Root cause 1**: Callbacks stored in class instance variables didn't propagate to child fibers
  - **Root cause 2**: `restore()` triggered agent initialization before logging setup, skipping callback registration
  - **Root cause 3**: Callbacks passed stale `@agent_context.swarm_id` that overrode Fiber-local storage
  - **Fix 1**: LogCollector uses Fiber-local storage (`Fiber[:log_callbacks]`) for thread-safe callback propagation
  - **Fix 2**: Retroactive callback registration via `setup_logging_for_all_agents` when agents initialized early
  - **Fix 3**: Removed explicit `swarm_id`/`parent_swarm_id` from LogStream.emit calls in callbacks
  - **Fix 4**: Scheduler leak prevention - force cleanup of lingering Async schedulers between requests
  - **Fix 5**: Fresh callback array per execution to prevent accumulation
  - **Result**: All events (agent_step, tool_call, delegation, etc.) now work correctly in Puma/Sidekiq
  - **Rails integration**: Works seamlessly without service code changes

### Added

- **Configurable System Prompt Restoration**: Control whether system prompts come from current config or historical snapshot
  - **`preserve_system_prompts`** parameter in `swarm.restore()` and `orchestrator.restore()` (default: `false`)
  - **Default behavior (`false`)**: System prompts from current agent definitions (YAML + SDK defaults + plugin injections)
    - Enables system prompt iteration without creating new sessions
    - Configuration is source of truth for agent behavior
    - External session management with prompt updates works seamlessly
  - **Historical mode (`true`)**: System prompts from snapshot (exact historical state)
    - For debugging: "What instructions was agent following when bug occurred?"
    - For auditing: "What exact prompts were active at that time?"
    - For reproducibility: "Replay with exact historical context"
  - **Applies to all agents**: Primary agents and delegation instances
  - **Includes all injections**: YAML config, SDK defaults, SwarmMemory instructions, plugin additions
  - **Non-breaking**: Backward compatible, all existing code works unchanged
  - **Documentation**: Complete guide in `docs/v2/guides/snapshots.md` with examples and comparisons

- **System-Wide Filesystem Tools Control**: Global security setting to disable filesystem tools across all agents
  - **`SwarmSDK.config.allow_filesystem_tools`** - Global setting to enable/disable filesystem tools (default: true)
  - **Environment variable**: `SWARM_SDK_ALLOW_FILESYSTEM_TOOLS` - Set via environment for production deployments
  - **Parameter override**: `allow_filesystem_tools:` parameter in `SwarmSDK.build`, `load`, and `load_file`
  - **Filesystem tools**: Read, Write, Edit, MultiEdit, Grep, Glob, Bash
  - **Validation**: Build-time validation catches forbidden tools early with clear error messages
  - **Non-breaking**: Defaults to `true` for backward compatibility
  - **Security boundary**: External to swarm configuration - cannot be overridden by YAML/DSL
  - **Tools still allowed**: Think, TodoWrite, Clock, WebFetch, ScratchpadRead/Write/List, Memory tools
  - **Use cases**: Multi-tenant platforms, sandboxed execution, containerized environments, compliance requirements
  - **Priority resolution**: Explicit parameter > Global setting > Environment variable > Default (true)
  - **26 comprehensive tests** covering all configuration and validation scenarios
  - **Documentation**: Complete implementation guide in `FILESYSTEM_TOOLS_CONTROL_PLAN.md`

- **Snapshot Reconstruction from Events**: Complete StateSnapshot reconstruction from event logs
  - **`SwarmSDK::SnapshotFromEvents`** class reconstructs full swarm state from event stream
  - **100% state reconstruction** - All components recoverable: conversations, context state, scratchpad, read tracking, delegation instances
  - **Event sourcing ready** - Events are single source of truth, snapshots derived on-demand
  - **Time travel debugging** - Reconstruct state at any point in time by filtering events
  - **Session persistence** - Store only events in database, reconstruct snapshots when needed
  - **`SwarmSDK::EventsToMessages`** helper class for message reconstruction with chronological ordering
  - **Database/Redis patterns** - Complete examples for event-based session storage
  - **Hybrid optimization** - Periodic snapshots + delta events for performance
  - **Performance**: 1,000 events in ~10-20ms, 10,000 events in ~100-200ms
  - **29 comprehensive tests** verifying event data capture and reconstruction accuracy
  - **Documentation**: Complete guide in `docs/v2/guides/snapshots.md` with patterns and examples

- **Event Timestamp Guarantee**: All events now guaranteed to have timestamps
  - **Automatic timestamp injection** in `LogCollector.emit` if missing
  - **Format**: ISO 8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`)
  - **Preserves existing timestamps** - Won't overwrite if already present
  - **Dual injection points** - LogStream and LogCollector both ensure timestamps
  - **Chronological ordering** - Enables proper event sequencing for reconstruction
  - **Updated test**: Verifies timestamp presence and preservation

- **Context Threshold Tracking**: New event for tracking which warning thresholds were hit
  - **`context_threshold_hit`** event emitted when threshold crossed for first time
  - **Contains**: `threshold` (integer: 60, 80, 90, 95), `current_usage_percentage`
  - **Enables reconstruction** of `context_state.warning_thresholds_hit` from events
  - **Separate from context_limit_warning** - Hit tracking vs informational warning

- **Read Tracking Digest in Events**: File read digests now included in tool_result metadata
  - **`metadata.read_digest`** - SHA256 digest of read file content
  - **`metadata.read_path`** - Absolute path to file
  - **Added via `extract_tool_tracking_digest`** method after tool execution
  - **Queries ReadTracker** after read completes to get calculated digest
  - **Enables reconstruction** of complete read_tracking state from events
  - **Works for all file types** - Text files, binary files, documents

- **Memory Read Tracking Digest in Events**: Memory read digests included in tool_result metadata
  - **`metadata.read_digest`** - SHA256 digest of memory entry content
  - **`metadata.read_path`** - Memory entry path
  - **Unified handling** with file read tracking via same extraction method
  - **Enables reconstruction** of complete memory_read_tracking state from events
  - **Cross-gem coordination** - SwarmMemory and SwarmSDK work together seamlessly

- **Execution ID and Complete Swarm ID Tracking**: All log events now include comprehensive execution tracking fields
  - **`execution_id`**: Uniquely identifies a single `swarm.execute()` or `orchestrator.execute()` call
    - Format: `exec_{swarm_id}_{random_hex}` for swarms (e.g., `exec_main_a3f2b1c8`)
    - Format: `exec_workflow_{random_hex}` for workflows (e.g., `exec_workflow_abc123`)
    - Enables calculating total cost/tokens for a single execution
    - Allows building complete execution traces across all agents and tools
  - **`swarm_id`**: Identifies which swarm/node emitted the event
    - Hierarchical format for Workflow nodes (e.g., `workflow/node:planning`)
    - Tracks execution flow through nested swarms and workflow stages
  - **`parent_swarm_id`**: Identifies the parent swarm for nested execution contexts
  - **Fiber-local storage implementation**: Uses Ruby 3.2+ Fiber storage for automatic propagation
    - IDs automatically inherit to child fibers (tools, delegations, nested executions)
    - Mini-swarms in workflows inherit orchestrator's execution_id while maintaining node-specific swarm_ids
    - Zero manual propagation needed - all handled by `LogStream.emit()` auto-injection
  - **Smart cleanup pattern**: Uses `block_given?` to determine cleanup responsibility
    - Standalone swarms clear Fiber storage after execution
    - Mini-swarms preserve parent's execution context for workflow continuity
  - **Comprehensive coverage**: 30 out of 31 event types now have complete tracking
    - All events except optional `claude_code_conversion_warning` (backward compatibility)
  - **Production-ready**: Minimal code changes (3 files, ~28 lines), zero performance impact
  - **Fully tested**: 10 comprehensive test cases covering uniqueness, inheritance, isolation, and cleanup

- **Composable Swarms**: Build reusable swarm components that can be composed together
  - **New `id()` DSL method**: Set unique swarm identifier (required when using composable swarms)
  - **New `swarms {}` DSL block**: Register external swarms for delegation
  - **New `register()` method**: Three registration methods:
    - `register "name", file: "./swarm.rb"` - Load from file
    - `register "name", yaml: yaml_string` - Load from YAML string
    - `register "name" { ... }` - Define inline with DSL block
  - **`keep_context` parameter**: Control conversation persistence per swarm (default: true)
  - **Hierarchical swarm IDs**: Parent/child tracking (e.g., `main/code_review/security`)
  - **Transparent delegation**: Use swarms in `delegates_to` like regular agents
  - **Lazy loading & caching**: Sub-swarms loaded on first access and cached
  - **Circular dependency detection**: Runtime prevention of infinite delegation loops
  - **Event tracking**: All events include `swarm_id` and `parent_swarm_id` fields
  - **SwarmRegistry class**: Manages sub-swarm lifecycle and cleanup
  - **SwarmLoader class**: Multi-source loader (files, YAML strings, blocks)
  - **Deep nesting support**: Unlimited levels of swarm composition
  - **Cleanup cascade**: Proper resource cleanup through hierarchy
  - **YAML support**: `id:` and `swarms:` sections with file/inline definitions
  - **Comprehensive tests**: 36 new tests, 100% pass rate

- **Per-Delegation Agent Instances**: Dual-mode delegation support with isolated and shared modes
  - **New `shared_across_delegations` configuration** (default: `false`)
    - `false` (default): Each delegator gets its own isolated instance with separate conversation history
    - `true`: All delegators share the same primary agent instance (legacy behavior)
  - **Prevents context mixing**: Multiple agents delegating to the same target no longer share conversation history by default
  - **Instance naming**: Delegation instances follow `"delegate@delegator"` pattern (e.g., `"tester@frontend"`)
  - **Memory sharing**: Plugin storage (SwarmMemory) shared by base name across all instances
  - **Tool state isolation**: TodoWrite, ReadTracker, and other stateful tools isolated per instance
  - **Nested delegation support**: Works correctly with multi-level delegation chains
  - **Fiber-safe concurrency**: Added `Async::Semaphore` to `Chat.ask()` to prevent message corruption when multiple delegation instances call shared agents in parallel
  - **Atomic caching**: Workflow caches delegation instances together with primary agents for context preservation
  - **Agent name validation**: Agent names cannot contain '@' character (reserved for delegation instances)
  - **Automatic deduplication**: Duplicate entries in `delegates_to` are automatically removed
  - **Comprehensive test coverage**: 17 new tests covering isolated mode, shared mode, nested delegation, cleanup, and more

- **YAML-to-DSL Internal Refactor**: Configuration class now uses DSL internally for swarm construction
  - **New `Configuration.to_swarm` implementation**: Translates YAML to Ruby DSL calls instead of direct API
  - **Better separation of concerns**: YAML parsing separated from swarm building logic
  - **Node workflow support in YAML**: Full support for multi-stage node-based workflows
  - **Improved translation methods**: `translate_agents`, `translate_all_agents`, `translate_nodes`, `translate_swarm_hooks`
  - **Stricter validation**: Agent descriptions now required in YAML (caught earlier with better error messages)
  - **Test coverage**: Added `yaml_node_support_test.rb` with comprehensive node workflow tests

- **YAML Hooks & Permissions**: Fixed and improved YAML configuration for hooks and permissions
  - **Hooks now work correctly**: Fixed translation from YAML to DSL
  - **Permissions properly translated**: Complex permission configurations now work in YAML
  - **Documentation improvements**: Updated YAML reference with correct examples
  - **Cleaner agent builder**: Removed redundant hook/permission handling code

### Fixed

- **StateSnapshot tool_calls serialization**: Fixed bug where tool_calls couldn't be serialized
  - **Issue**: `msg.tool_calls.map(&:to_h)` failed because tool_calls is a Hash, not Array
  - **Fix**: Changed to `msg.tool_calls.values.map(&:to_h)` to properly serialize
  - **Impact**: Snapshots with tool calls now serialize correctly
  - **Location**: `lib/swarm_sdk/state_snapshot.rb:154`

- **ReadTracker and StorageReadTracker return digest**: Both trackers now return calculated digest
  - **Changed**: `register_read` methods now return SHA256 digest string
  - **Enables**: Digest extraction after tool execution for event metadata
  - **Backward compatible**: Return value wasn't previously used

### Changed

- **Breaking: Default tools reduced to essential file operations only**
  - **Old default tools**: Read, Grep, Glob, WebFetch, TodoWrite, Clock, Think
  - **New default tools**: Read, Grep, Glob
  - **Removed from defaults**: WebFetch, TodoWrite, Clock, Think
  - **Rationale**: Follows principle of least privilege - users have complete control over agent capabilities
  - **Migration**: Explicitly add removed tools if needed: `tools :Read, :Grep, :Glob, :WebFetch, :TodoWrite, :Clock, :Think`
  - **Impact**: Agents will no longer have WebFetch, TodoWrite, Clock, or Think unless explicitly added
  - **Documentation updated**: All guides and references now show correct default tools

- **Breaking: Default delegation behavior changed**
  - **Old behavior**: Multiple agents delegating to same target shared conversation history
  - **New behavior**: Each delegator gets isolated instance with separate history (prevents context mixing)
  - **Migration**: Add `shared_across_delegations: true` to agents that need the old shared behavior
  - **Impact**: Existing swarms will see different behavior - agents no longer share delegation contexts by default

- **Ruby version upgraded**: 3.4.2 → 3.4.5
  - Updated `.ruby-version` file
  - All dependencies compatible with Ruby 3.4.5

- **RubyLLM upgraded**: 1.8.2 → 1.9.0
  - Updated to latest RubyLLM gem version
  - Updated ruby_llm-mcp integration
  - Disabled MCP lazy loading for better compatibility
  - See RubyLLM changelog for full details

- **YAML Configuration Loading**: Improved YAML parsing and validation
  - **Stricter validation**: Required fields now validated earlier with better error messages
  - **Better error context**: Error messages include field paths and agent names
  - **Node workflow validation**: Full validation for node dependencies and transformers

- **TodoWrite system reminders**: Only injected when TodoWrite tool is available
  - Fixed bug where TodoWrite reminders appeared even when tool was disabled
  - System reminders now conditional based on agent's actual toolset
  - Cleaner agent output when TodoWrite is not needed

### Fixed

- **Node context preservation bug**: Fixed issue where `inject_cached_agents` would be overwritten by fresh initialization
  - Added forced initialization before injection to ensure cached instances are preserved
- **Nested delegation race condition**: Added per-instance semaphore to prevent concurrent `ask()` calls from corrupting shared agent message history
- **Hash iteration bug**: Fixed "can't add key during iteration" error in nested delegation by using `.to_a`
- **YAML hooks translation**: Fixed hooks not being properly translated from YAML to DSL
- **YAML permissions handling**: Fixed permissions configurations not working correctly in YAML

## [2.1.3]

### Added

- **Validation API**: New methods to validate YAML configurations without creating swarms
  - `SwarmSDK.validate(yaml_content, base_dir:)` - Validate YAML string and return structured errors
  - `SwarmSDK.validate_file(path)` - Validate YAML file (convenience method)
  - Returns array of error hashes with type, field path, message, and optional agent name
  - Error types: `:syntax_error`, `:missing_field`, `:invalid_value`, `:invalid_reference`, `:directory_not_found`, `:file_not_found`, `:file_load_error`, `:circular_dependency`, `:validation_error`, `:unknown_error`
  - Field paths use JSON-style notation: `"swarm.agents.backend.description"`
  - Enables pre-flight validation for UIs, tools, and programmatic usage
  - Comprehensive test coverage with 19 tests covering all error scenarios

- **String-based Configuration Loading**: Load YAML from strings, not just files
  - `SwarmSDK.load(yaml_content, base_dir:)` - Load swarm from YAML string (primary API)
  - `SwarmSDK.load_file(path)` - Load swarm from YAML file (convenience method)
  - `base_dir` parameter for resolving agent file paths (defaults to `Dir.pwd`)
  - Enables loading YAML from databases, APIs, environment variables, or any string source
  - Cleaner separation: SDK works with strings, CLI handles file I/O

### Changed

- **BREAKING: Removed `Swarm.load` class method**
  - Old: `swarm = SwarmSDK::Swarm.load("config.yml")`
  - New: `swarm = SwarmSDK.load_file("config.yml")`
  - Cleaner API: All creation methods now at module level (`SwarmSDK.build`, `SwarmSDK.load`, `SwarmSDK.load_file`)

- **BREAKING: `Configuration` class refactored for string-based loading**
  - Old: `Configuration.load(path)` → New: `Configuration.load_file(path)`
  - Old: `Configuration.new(path)` → New: `Configuration.new(yaml_content, base_dir: Dir.pwd)`
  - Removed `config_path` attribute (no longer stored)
  - Internal: `@config_dir` renamed to `@base_dir`
  - Core SDK now works with YAML strings, not file paths
  - File I/O isolated to convenience methods (`load_file`)

- **Agent file path resolution**: Paths resolved relative to `base_dir`
  - When loading from file: `base_dir` = file's directory (unchanged behavior)
  - When loading from string: `base_dir` = `Dir.pwd` (default) or explicit parameter
  - Example: `agent_file: "agents/backend.md"` resolves to `#{base_dir}/agents/backend.md`

### Fixed

- **Configuration validation**: Better error messages with file context
  - YAML syntax errors now include parser details
  - File not found errors include absolute paths
  - Agent file load errors include agent name and field path

## [2.1.2]

### Added

- **Node Workflow Control Flow**: Dynamic control methods in NodeContext
  - `ctx.goto_node(:node_name, content:)` - Jump to any node with custom content
  - `ctx.halt_workflow(content:)` - Stop entire workflow and return final result
  - `ctx.skip_execution(content:)` - Skip node LLM execution and use provided content
  - Enables loops, conditional branching, and dynamic routing in workflows
  - All methods validate that content is not nil (raises ArgumentError with helpful message if nil)
  - Use for implementing retry logic, convergence checks, caching, and iterative refinement

- **Context Preservation Across Nodes**: `reset_context` parameter for node agents
  - `agent(:name, reset_context: false)` preserves conversation history across nodes
  - Default: `reset_context: true` (fresh context for each node - safe default)
  - Workflow caches and reuses agent instances when `reset_context: false`
  - Enables stateful workflows where agents remember previous node conversations
  - Perfect for iterative refinement, self-reflection loops, and chain-of-thought reasoning

### Changed

- **Result object**: Cost and tokens now calculated dynamically from logs
  - `result.cost` and `result.tokens` now properly populated after swarm execution
  - Values are calculated from usage data in logs, not stored during initialization
  - Fixed issue where these attributes were always 0/empty

- **Plugin serialization**: New `serialize_config` hook for plugin extensibility
  - Plugins can now contribute to `Agent::Definition.to_h` via `serialize_config` hook
  - Removes memory-specific code from SwarmSDK core (moved to SwarmMemory plugin)
  - Maintains backward compatibility - permissions remain in core SDK (not plugin-specific)
  - Enables clean separation between core SDK and plugin features (memory, skills, etc.)
  - Plugins can preserve their configuration when agents are cloned in Workflow

- **Workflow**: Configurable scratchpad sharing modes
  - `scratchpad: :enabled` - Share scratchpad across all nodes
  - `scratchpad: :per_node` - Isolated scratchpad per node
  - `scratchpad: :disabled` - No scratchpad tools (default)

- **CLI ConfigLoader**: Accepts both Swarm and Workflow instances
  - Bug fix: CLI now correctly handles Workflow execution
  - Enables node workflows to work seamlessly with CLI commands

- **Error handling in Agent::Chat**: More robust exception handling
  - Changed nil response error from `RubyLLM::Error` to `StandardError`
  - Prevents "undefined method 'body'" error when handling malformed API responses

## [2.1.1]

### Added
- **OpenAI proxy compatibility**: New `openai_use_system_role` configuration
  - Automatically enabled for OpenAI-compatible providers (OpenAI, DeepSeek, Perplexity, Mistral, OpenRouter)
  - Uses standard 'system' role instead of OpenAI's newer 'developer' role
  - Improves compatibility with proxy services that don't support 'developer' role
  - Configured automatically based on provider type

### Changed
- **Think tool parameter handling**: Simplified to accept flexible parameters
  - Changed signature from `execute(thoughts:)` to `execute(**kwargs)`
  - Removes strict validation errors for parameter mismatches
  - More flexible for LLM tool calling variations
  - Added reminder in description: "The Think tool takes only one parameter: thoughts"

### Fixed
- **Nil response error handling**: Better error messages for malformed API responses
  - Detects when provider returns nil response (unparseable API response)
  - Provides detailed error message with provider info, API base, model ID
  - Suggests enabling RubyLLM debug logging to inspect raw API response
  - Prevents cryptic errors when API returns malformed/unparseable responses

## [2.1.0] - 2025-10-27

### Added
- **Think tool for explicit reasoning**: New built-in tool that enables agents to "think out loud"
  - Parameter: `thoughts` - records agent's thinking process as function calls
  - Creates "attention sinks" in conversation history for better reasoning
  - Based on chain-of-thought prompting research
  - Included as a default tool for all agents
  - Usage: `Think(thoughts: "Let me break this down: 1) Read file, 2) Analyze, 3) Implement")`

- **disable_default_tools configuration**: Flexible control over which default tools are included
  - Accepts `true` to disable ALL default tools
  - Accepts array to disable specific tools: `[:Think, :TodoWrite]`
  - Works in both Ruby DSL and YAML configurations
  - Example: `disable_default_tools [:Think, :Grep]` keeps other defaults

### Fixed
- **Model alias resolution**: Fixed bug where model aliases weren't resolved before being passed to RubyLLM
  - Aliases like `sonnet`, `opus`, `haiku` now properly resolve to full model IDs
  - `sonnet` → `claude-sonnet-4-5-20250929`
  - Works with both Ruby DSL and markdown agent files
  - Prevents "model does not exist" API errors when using aliases

### Changed
- **BREAKING CHANGE: Removed include_default_tools**: Replaced with `disable_default_tools`
  - Migration: `include_default_tools: false` → `disable_default_tools: true`
  - More intuitive API (disable what you don't want vs enable what you do)
  - Updated all documentation and examples

## [2.0.8] - 2025-10-27
- Bump RubyLLM MCP gem and remove monkey patch

## [2.0.7] - 2025-10-26

### Added

- **Plugin System** - Extensible architecture for decoupling core SDK from extensions
  - `SwarmSDK::Plugin` base class with lifecycle hooks
  - `SwarmSDK::PluginRegistry` for plugin management
  - Plugins provide tools, storage, configuration, and system prompt contributions
  - Lifecycle hooks: `on_agent_initialized`, `on_swarm_started`, `on_swarm_stopped`, `on_user_message`
  - Zero coupling: SwarmSDK has no knowledge of SwarmMemory classes
  - Auto-registration: Plugins register themselves when loaded
  - See new guide: `docs/v2/guides/plugins.md`

- **ContextManager** - Intelligent conversation context optimization
  - **Ephemeral System Reminders**: Sent to LLM but not persisted (90% token savings)
  - **Automatic Compression**: Triggers at 60% context usage
  - **Progressive Compression**: Older tool results compressed more aggressively
  - **Smart Re-run Instructions**: Idempotent tools (Read, Grep, Glob) get re-run hints
  - Token savings: 13,800-63,800 tokens per long conversation
  - See documentation: `docs/v2/reference/ruby-dsl.md#context-management`

- **Agent Name Tracking** - `Agent::Chat` now tracks `@agent_name`
  - Enables plugin callbacks per agent
  - Used for semantic skill discovery
  - Passed to lifecycle hooks

- **Parameter Validation** - Validates required parameters before tool execution
  - Checks all required parameters are present
  - Provides detailed error messages with parameter descriptions
  - Prevents "missing keyword" errors from reaching tools
  - Replaces Ruby's "keyword" terminology with user-friendly "parameter"

### Changed

- **Tool Registration** - Moved from hardcoded to plugin-based
  - Memory tools no longer hardcoded in ToolConfigurator
  - Plugins provide their own tools via `plugin.tools` and `plugin.create_tool()`
  - `MEMORY_TOOLS` constant removed (now in plugin)
  - ToolConfigurator uses `PluginRegistry.plugin_tool?()` for lookups

- **Storage Management** - Generalized for plugins
  - `@memory_storages` → `@plugin_storages` (supports any plugin)
  - Format: `{ plugin_name => { agent_name => storage } }`
  - Plugins create their own storage via `plugin.create_storage()`

- **System Prompt Contributions** - Plugin-based
  - `Agent::Definition` collects contributions from all plugins
  - Plugins contribute via `plugin.system_prompt_contribution()`
  - No hardcoded memory prompt rendering in SDK

- **Context Warning Thresholds** - Expanded
  - **Was**: [80, 90]
  - **Now**: [60, 80, 90]
  - 60% triggers automatic compression
  - 80%/90% remain as informational warnings

### Removed

- **Tools::Registry Extension System** - Replaced by plugin system
  - `register_extension()` method removed
  - Extensions no longer checked in `get()`, `exists()`, `available_names()`
  - Use `PluginRegistry` instead for extension tools

### Breaking Changes

⚠️ **Major breaking changes:**

1. **No backward compatibility with old memory integration**
   - Old `Tools::Registry.register_extension()` removed
   - Memory tools MUST use plugin system
   - SwarmMemory updated to use plugin (no migration needed if using latest)

2. **Tool creation signature changed**
   - `create_tool_instance()` now accepts `chat:` and `agent_definition:` parameters
   - Needed for plugin tools that require full context

3. **AgentInitializer signature changed**
   - Constructor now takes `plugin_storages` instead of `memory_storages`
   - Internal change - doesn't affect public API

## [2.0.6]

### Fixed
- **MCP parameter type handling**: Fixed issue with parameter type conversion in ruby_llm-mcp
  - Added monkey patch to remove `to_sym` conversion on MCP parameter types

## [2.0.5]

### Added

- **WebFetch Tool** - Fetch and process web content
  - Fetches URLs and converts HTML to Markdown
  - Optional LLM processing via `SwarmSDK.configure { |c| c.webfetch_provider; c.webfetch_model }`
  - Uses `reverse_markdown` gem if installed, falls back to built-in converter
  - 15-minute caching, redirect detection, comprehensive error handling
  - Default tool (available to all agents)

- **HtmlConverter** - HTML to Markdown conversion
  - Conditional gem usage pattern (uses `reverse_markdown` if installed)
  - Built-in fallback for common HTML elements
  - Follows DocumentConverter pattern for consistency

- **Memory System** - Per-agent persistent knowledge storage
  - **MemoryStorage class**: Persistent storage to `{directory}/memory.json`
  - **7 Memory tools**: MemoryWrite, MemoryRead, MemoryEdit, MemoryMultiEdit, MemoryGlob, MemoryGrep, MemoryDelete
  - Per-agent isolation (each agent has own memory)
  - Search results ordered by most recent first
  - Configured via `memory { directory }` DSL or `memory:` YAML field
  - Auto-injected memory system prompt from `lib/swarm_sdk/prompts/memory.md.erb`
  - Comprehensive learning protocols and schemas included

- **Memory Configuration DSL**
  ```ruby
  agent :assistant do
    memory do
      adapter :filesystem  # optional, default
      directory ".swarm/assistant-memory"  # required
    end
  end
  ```

- **Memory Configuration YAML**
  ```yaml
  agents:
    assistant:
      memory:
        adapter: filesystem
        directory: .swarm/assistant-memory
  ```

- **Scratchpad Configuration DSL** - Configure mode at swarm/workflow level
  ```ruby
  SwarmSDK.build do
    scratchpad :enabled   # or :per_node (nodes only), :disabled (default: :disabled)
  end
  ```

- **Scratchpad Configuration YAML**
  ```yaml
  swarm:
    scratchpad: enabled  # or per_node (nodes only), disabled
  ```

- **Agent Start Events** - New log event after agent initialization
  - Emits `agent_start` with full agent configuration
  - Includes: agent, model, provider, directory, system_prompt, tools, delegates_to, memory_enabled, memory_directory, timestamp
  - Useful for debugging and configuration verification

- **SwarmSDK Global Settings** - `SwarmSDK.configure` for global configuration
  - WebFetch settings: `webfetch_provider`, `webfetch_model`, `webfetch_base_url`, `webfetch_max_tokens`
  - Separate from YAML Configuration class (renamed to Settings internally)

- **Learning Assistant Example** - Complete example in `examples/learning-assistant/`
  - Agent that learns and builds knowledge over time
  - Memory schema with YAML frontmatter + Markdown
  - Example memory entries (concept, fact, skill, experience)
  - Comprehensive learning protocols and best practices

### Changed

- **Scratchpad Architecture** - Complete redesign
  - **Was**: Single persistent storage with comprehensive tools (Edit, Glob, Grep, etc.)
  - **Now**: Simplified volatile storage with 3 tools (Write, Read, List)
  - **Purpose**: Temporary work-in-progress sharing between agents
  - **Scope**: Shared across all agents (volatile, in-memory only)
  - **Old comprehensive features** moved to Memory system

- **Storage renamed**: `updated_at` instead of `created_at`
  - More accurate since writes update existing entries
  - Affects both MemoryStorage and ScratchpadStorage

- **Storage architecture** - Introduced abstract base class
  - `Storage` (abstract base)
  - `MemoryStorage` (persistent, per-agent)
  - `ScratchpadStorage` (volatile, shared)
  - Future-ready for SQLite and FAISS adapters

- **Default tools** - Conditional inclusion
  - Core defaults: Read, Grep, Glob
  - Scratchpad tools: Added if `scratchpad: :enabled` (default)
  - Memory tools: Added if agent has `memory` configured
  - Enables fine-grained control over tool availability

- **Cost Tracking** - Fixed to use SwarmSDK's models.json
  - **Was**: Used `RubyLLM.models.find()` which lacks current model pricing
  - **Now**: Uses `SwarmSDK::Models.find()` with up-to-date pricing
  - Accurate cost calculation for all models in SwarmSDK registry

- **Read tracker renamed**: `ScratchpadReadTracker` → `StorageReadTracker`
  - More general name since it's used by both Memory and Scratchpad
  - Consistent with Storage abstraction

### Removed

- **Old Scratchpad tools** - Moved to Memory system
  - ScratchpadEdit → MemoryEdit
  - ScratchpadMultiEdit → MemoryMultiEdit
  - ScratchpadGlob → MemoryGlob
  - ScratchpadGrep → MemoryGrep
  - ScratchpadDelete → MemoryDelete

- **Scratchpad persistence** - Now volatile
  - No longer persists to `.swarm/scratchpad.json`
  - Use Memory system for persistent storage

### Breaking Changes

⚠️ **Major breaking changes requiring migration:**

1. **Scratchpad tools removed**: ScratchpadEdit, ScratchpadMultiEdit, ScratchpadGlob, ScratchpadGrep, ScratchpadDelete
   - **Migration**: Use Memory tools instead for persistent storage needs

2. **Scratchpad is now volatile**: Does not persist across sessions
   - **Migration**: Configure `memory` for agents that need persistence

3. **Storage field renamed**: `created_at` → `updated_at`
   - **Migration**: Old persisted scratchpad.json files will not load

4. **Default tools behavior changed**: Memory and Scratchpad are conditional
   - Scratchpad: Enabled by default via `scratchpad: :enabled`
   - Memory: Opt-in via `memory` configuration
   - **Migration**: Explicitly configure if needed

## [2.0.4]

### Added
- **ScratchpadGlob Tool** - Search scratchpad entries by glob pattern
  - Supports `*` (wildcard), `**` (recursive), and `?` (single char) patterns
  - Returns matching entries with titles and sizes
  - Example: `ScratchpadGlob.execute(pattern: "parallel/*/task_*")`
- **ScratchpadGrep Tool** - Search scratchpad content by regex pattern
  - Case-sensitive and case-insensitive search options
  - Three output modes: `files_with_matches`, `content` (with line numbers), `count`
  - Example: `ScratchpadGrep.execute(pattern: "error", output_mode: "content")`
- **ScratchpadRead Line Numbers** - Now returns formatted output with line numbers
  - Uses same format as Read tool: `"line_number→content"`
  - Compatible with Edit/MultiEdit tools for accurate content matching
- **ScratchpadEdit Tool** - Edit scratchpad entries with exact string replacement
  - Performs exact string replacements in scratchpad content
  - Enforces read-before-edit rule for safety
  - Supports `replace_all` parameter for multiple replacements
  - Preserves entry titles when updating content
  - Example: `ScratchpadEdit.execute(file_path: "report", old_string: "draft", new_string: "final")`
- **ScratchpadMultiEdit Tool** - Apply multiple edits to a scratchpad entry
  - Sequential edit application (later edits see results of earlier ones)
  - JSON-based edit specification for multiple operations
  - All-or-nothing approach: if any edit fails, no changes are saved
  - Example: `ScratchpadMultiEdit.execute(file_path: "doc", edits_json: '[{"old_string":"foo","new_string":"bar"}]')`
- **Scratchpad Persistence** - Automatic JSON file persistence
  - All scratchpad data automatically persists to `.swarm/scratchpad.json`
  - Thread-safe write operations with atomic file updates
  - Automatic loading on initialization
  - Graceful error handling for corrupted files
  - Human-readable JSON format with metadata (title, created_at, size)

### Changed
- **Scratchpad Data Location** - Moved from memory-only to persistent storage
  - Data survives swarm restarts
  - Stored in `.swarm/scratchpad.json` (hidden directory)
  - Added to `.gitignore` to prevent committing scratchpad data
- **Test Infrastructure** - Dependency injection for test isolation
  - Tests use temporary files instead of `.swarm/scratchpad.json`
  - New helper: `create_test_scratchpad()` for isolated test data
  - Automatic cleanup of test files after test runs

### Removed
- **ScratchpadList Tool** - Replaced by more powerful ScratchpadGlob
  - Use `ScratchpadGlob.execute(pattern: "**")` to list all entries
  - Use `ScratchpadGlob.execute(pattern: "prefix/**")` to filter by prefix

## [2.0.2] - 2025-10-17

### Added
- **Claude Code Agent File Compatibility** (#141)
  - Automatically detects and converts Claude Code agent markdown files
  - Supports model shortcuts: `sonnet`, `opus`, `haiku` → latest model IDs
  - DSL/YAML overrides: `agent :name, File.read("file.md") do ... end`
  - Model alias system via `model_aliases.json` for easy updates
  - Static model validation using `models.json` (no network calls, no API keys)
  - Improved model suggestions with provider prefix stripping

### Changed
- Model validation now uses SwarmSDK's static registry instead of RubyLLM's dynamic registry
- All agents now use `assume_model_exists: true` by default (SwarmSDK validates separately)
- Model suggestions properly handle provider-prefixed queries (e.g., `anthropic:claude-sonnet-4-5`)
- Environment block (`<env>`) now included in ALL agent system prompts (previously only `coding_agent: true`)

## [2.0.1] - 2025-10-17

### Fixed
- Add id to MCP notifications/initialized message (#140)

### Removed
- Removed outdated example files (examples/v2/README-formats.md and examples/v2/mcp.json)

## [2.0.0] - 2025-10-17

Initial release of SwarmSDK.

See https://github.com/parruda/claude-swarm/pull/137
