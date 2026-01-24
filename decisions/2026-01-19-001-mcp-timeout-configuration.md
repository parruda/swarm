# Decision: MCP Timeout Configuration and Reconnection Options

**Date:** 2026-01-19
**Status:** Implemented
**Author:** SwarmSDK Team

## Context

Users were experiencing frequent SSE stream timeout errors:
```
ERROR -- RubyLLM::MCP: SSE stream error: Request timed out after 30 seconds
```

The root cause was identified:
1. The default MCP timeout was hardcoded to 30 seconds in `McpConfigurator`
2. This timeout is used as `operation_timeout` in HTTPX, which limits the **entire SSE stream duration**, not just individual reads
3. For long-running SSE connections (common in real-time MCP communication), 30 seconds is insufficient

## Decision

### 1. Configurable MCP Timeout (Default: 300 seconds)

Added `mcp_request_timeout` configuration option:
- Default: 300 seconds (5 minutes)
- Configurable via environment variable: `SWARM_SDK_MCP_REQUEST_TIMEOUT`
- Configurable programmatically via `SwarmSDK.configure`

The 5-minute default accommodates:
- Long-running tool executions
- Extended SSE stream connections
- Complex MCP operations

### 2. Reconnection Options for SSE/Streamable Transports

Added automatic reconnection configuration with exponential backoff:
- `max_retries`: 5 (default)
- `initial_reconnection_delay`: 2 seconds (default)
- `reconnection_delay_grow_factor`: 2.0 (doubles each retry)
- `max_reconnection_delay`: 60 seconds (cap)

This provides resilience against transient network issues.

### 3. Per-Server Timeout Override

Individual MCP servers can still specify their own timeout:
```ruby
mcp_server :my_server, type: :streamable, url: "...", timeout: 600
```

## Implementation

### Files Changed

1. **lib/swarm_sdk/defaults.rb**
   - Added `Timeouts::MCP_REQUEST_SECONDS = 300`
   - Added `McpReconnection` module with reconnection defaults

2. **lib/swarm_sdk/config.rb**
   - Added `mcp_request_timeout` to `DEFAULTS_MAPPINGS`

3. **lib/swarm_sdk/swarm/mcp_configurator.rb**
   - Updated `initialize_mcp_client` to use `SwarmSDK.config.mcp_request_timeout`
   - Added `build_reconnection_options` method
   - Updated `build_sse_config` and `build_streamable_config` to include reconnection options

## Usage

### Configure Globally
```ruby
SwarmSDK.configure do |config|
  config.mcp_request_timeout = 600  # 10 minutes
end
```

### Environment Variable
```bash
export SWARM_SDK_MCP_REQUEST_TIMEOUT=600
```

### Per-Server Configuration
```ruby
SwarmSDK.build do
  agent :assistant do
    mcp_server :api, type: :streamable, url: "...", timeout: 600
    mcp_server :db, type: :streamable, url: "...", timeout: 120
  end
end
```

### Custom Reconnection Options
```ruby
SwarmSDK.build do
  agent :assistant do
    mcp_server :api,
      type: :streamable,
      url: "...",
      reconnection: {
        max_retries: 10,
        initial_delay: 1000,
        delay_grow_factor: 1.5,
        max_delay: 30_000
      }
  end
end
```

## Alternatives Considered

1. **Separate SSE timeout vs request timeout**: ruby_llm-mcp currently uses the same timeout for both. This would require upstream changes.

2. **Infinite timeout for SSE**: Too risky - could lead to zombie connections.

3. **Heartbeat-based keep-alive**: Would require protocol changes in ruby_llm-mcp.

## References

- ruby_llm-mcp StreamableHTTP transport implementation
- HTTPX timeout configuration (connect_timeout, read_timeout, write_timeout, operation_timeout)
- MCP Protocol specification for SSE streams
