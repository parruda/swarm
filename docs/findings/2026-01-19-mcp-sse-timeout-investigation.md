# MCP SSE Notification Stream Timeout Investigation

**Date:** 2026-01-19
**Status:** Documented (workaround implemented)

## Problem

Users experiencing frequent SSE stream timeout errors:
```
ERROR -- RubyLLM::MCP: SSE stream error: Request timed out after 300 seconds
```

The timeout occurs even though tool calls complete successfully.

## Root Cause Analysis

### Two Separate SSE Connections in ruby_llm-mcp

The StreamableHTTP transport maintains **two distinct types of SSE connections**:

1. **Per-Tool-Call SSE**: Created via `create_connection_with_streaming_callbacks` for individual tool requests. Uses dedicated connection per request.

2. **Background Notification SSE**: A long-lived thread (`start_sse_stream`, lines 455-465 in streamable_http.rb) that spawns a background thread meant to stay open for server-initiated notifications.

### The Timeout Problem

Both connections use the same `operation_timeout`:

```ruby
# From create_connection_with_sse_callbacks (lines 536-557)
client = client.with(
  timeout: {
    connect_timeout: 10,
    read_timeout: @request_timeout / 1000,      # Same timeout
    write_timeout: @request_timeout / 1000,     # Same timeout
    operation_timeout: @request_timeout / 1000  # THIS IS THE PROBLEM
  }
)
```

The `operation_timeout` is a **hard cap on total connection duration**. For the background SSE stream meant to stay open indefinitely, this is fatal.

### Timeout Flow

```
1. Client makes tool call → Tool executes successfully (uses its own connection)
2. Server returns response, triggers start_sse_stream()
3. Background thread opens GET request with Accept: text/event-stream
4. HTTPX starts operation_timeout countdown (300 seconds)
5. Server keeps connection open, waiting to send notifications
6. ... 300 seconds pass ...
7. HTTPX raises ReadTimeoutError
8. handle_httpx_error_response! converts to TimeoutError
9. Error logged: "SSE stream error: Request timed out after 300 seconds"
```

### Why Tool Calls Work Fine

Tool calls use their own dedicated connections (`create_connection_with_streaming_callbacks`). Each tool call creates a new connection, completes, and closes. The 300-second timeout is per-call, which is plenty.

The background notification stream is separate and times out independently.

## Current Workaround

Configured aggressive reconnection in `lib/swarm_sdk/defaults.rb`:

```ruby
module McpReconnection
  MAX_RETRIES = 1000          # Effectively infinite
  INITIAL_DELAY_MS = 500      # Fast initial reconnect
  DELAY_GROW_FACTOR = 1.2     # Slow growth
  MAX_DELAY_MS = 10_000       # Cap at 10 seconds
end
```

This ensures the SSE stream automatically reconnects after timing out. The reconnection is transparent to users since tool calls work on separate connections.

## Proper Fix (Requires ruby_llm-mcp Changes)

The proper fix would require changes to ruby_llm-mcp:

1. **Separate timeout configuration for SSE streams:**
```ruby
# Hypothetical API
client = RubyLLM::MCP::Client.new(
  name: "my-server",
  transport_type: :streamable,
  request_timeout: 60_000,      # For tool calls
  sse_timeout: nil,             # No timeout for background SSE
  config: { url: "..." }
)
```

2. **Disable operation_timeout for SSE connections:**
```ruby
# In create_connection_with_sse_callbacks:
client = client.with(
  timeout: {
    connect_timeout: 10,
    read_timeout: 60,           # Reset on each chunk
    write_timeout: 10,
    operation_timeout: nil      # No overall operation timeout for SSE!
  }
)
```

3. **Server-side heartbeat handling** to reset read_timeout periodically

## Impact

- Tool calls: **Unaffected** (use separate connections)
- Server notifications: **May have brief gaps** during reconnection (500ms-10s)
- If MCP server sends `Last-Event-ID` support, missed notifications can be recovered via resumption tokens

## References

- ruby_llm-mcp `streamable_http.rb` lines 455-534 (SSE stream implementation)
- HTTPX timeout documentation
- MCP Protocol SSE specification
