# Configuration Reference

This document provides a comprehensive reference for all SwarmSDK configuration options. Configuration can be set via environment variables or programmatically through `SwarmSDK.configure`.

## Configuration Priority

Values are resolved in this order:
1. **Explicit value** (set via `SwarmSDK.configure`)
2. **Environment variable**
3. **Default value**

## Usage

```ruby
SwarmSDK.configure do |config|
  # API Keys
  config.openai_api_key = "sk-..."

  # Defaults
  config.default_model = "claude-sonnet-4"
  config.agent_request_timeout = 600

  # WebFetch
  config.webfetch_provider = "anthropic"
  config.webfetch_model = "claude-3-5-haiku-20241022"
end
```

---

## API Keys

API keys are automatically proxied to `RubyLLM.config` when set.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `OPENAI_API_KEY` | `openai_api_key` | OpenAI API authentication key | `nil` |
| `OPENAI_API_BASE` | `openai_api_base` | Custom OpenAI-compatible API endpoint URL | `nil` |
| `OPENAI_ORG_ID` | `openai_organization_id` | OpenAI organization identifier | `nil` |
| `OPENAI_PROJECT_ID` | `openai_project_id` | OpenAI project identifier | `nil` |
| `ANTHROPIC_API_KEY` | `anthropic_api_key` | Anthropic (Claude) API authentication key | `nil` |
| `GEMINI_API_KEY` | `gemini_api_key` | Google Gemini API authentication key | `nil` |
| `GEMINI_API_BASE` | `gemini_api_base` | Custom Gemini API endpoint URL | `nil` |
| `GOOGLE_CLOUD_PROJECT` | `vertexai_project_id` | Google Cloud project ID for Vertex AI | `nil` |
| `GOOGLE_CLOUD_LOCATION` | `vertexai_location` | Google Cloud region for Vertex AI | `nil` |
| `DEEPSEEK_API_KEY` | `deepseek_api_key` | DeepSeek API authentication key | `nil` |
| `MISTRAL_API_KEY` | `mistral_api_key` | Mistral AI API authentication key | `nil` |
| `PERPLEXITY_API_KEY` | `perplexity_api_key` | Perplexity API authentication key | `nil` |
| `OPENROUTER_API_KEY` | `openrouter_api_key` | OpenRouter API authentication key | `nil` |
| `AWS_ACCESS_KEY_ID` | `bedrock_api_key` | AWS access key for Bedrock | `nil` |
| `AWS_SECRET_ACCESS_KEY` | `bedrock_secret_key` | AWS secret key for Bedrock | `nil` |
| `AWS_REGION` | `bedrock_region` | AWS region for Bedrock | `nil` |
| `AWS_SESSION_TOKEN` | `bedrock_session_token` | AWS session token for temporary credentials | `nil` |
| `OLLAMA_API_BASE` | `ollama_api_base` | Local Ollama server URL | `nil` |
| `GPUSTACK_API_BASE` | `gpustack_api_base` | GPUStack server URL | `nil` |
| `GPUSTACK_API_KEY` | `gpustack_api_key` | GPUStack API authentication key | `nil` |

---

## Agent & Swarm Defaults

Default values for agent and swarm configuration.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_DEFAULT_MODEL` | `default_model` | Default LLM model when not specified per-agent | `"gpt-5"` |
| `SWARM_SDK_DEFAULT_PROVIDER` | `default_provider` | Default LLM provider when not specified per-agent | `"openai"` |
| `SWARM_SDK_GLOBAL_CONCURRENCY_LIMIT` | `global_concurrency_limit` | Maximum concurrent API calls across entire swarm | `50` |
| `SWARM_SDK_LOCAL_CONCURRENCY_LIMIT` | `local_concurrency_limit` | Maximum parallel tool executions per agent | `10` |

---

## Timeouts

Timeout values for various operations.

### Execution & Turn Timeouts

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_DEFAULT_EXECUTION_TIMEOUT` | `default_execution_timeout` | Maximum wall-clock time for entire `swarm.execute()` call in seconds | `1800` (30 min) |
| `SWARM_SDK_DEFAULT_TURN_TIMEOUT` | `default_turn_timeout` | Maximum time for single `agent.ask()` call (LLM + tools) in seconds | `1800` (30 min) |
| `SWARM_SDK_AGENT_REQUEST_TIMEOUT` | `agent_request_timeout` | Single LLM HTTP request timeout (Faraday level) in seconds | `300` (5 min) |

**Note:** Set to `nil` to disable timeout enforcement. Per-agent and per-swarm overrides are available via DSL/YAML.

### Tool & Command Timeouts

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_BASH_COMMAND_TIMEOUT` | `bash_command_timeout` | Bash command execution timeout in milliseconds | `120000` (2 min) |
| `SWARM_SDK_BASH_COMMAND_MAX_TIMEOUT` | `bash_command_max_timeout` | Maximum allowed bash command timeout in milliseconds | `600000` (10 min) |
| `SWARM_SDK_WEB_FETCH_TIMEOUT` | `web_fetch_timeout` | HTTP request timeout for WebFetch tool in seconds | `30` |
| `SWARM_SDK_HOOK_SHELL_TIMEOUT` | `hook_shell_timeout` | Shell hook executor timeout in seconds | `60` |
| `SWARM_SDK_TRANSFORMER_COMMAND_TIMEOUT` | `transformer_command_timeout` | Workflow transformer command timeout in seconds | `60` |

---

## Output & Content Limits

Limits for output sizes and content lengths.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_OUTPUT_CHARACTER_LIMIT` | `output_character_limit` | Maximum characters in Bash command output | `30000` |
| `SWARM_SDK_READ_MAX_TOKENS` | `read_max_tokens` | Maximum tokens for Read tool file content | `25000` |
| `SWARM_SDK_WEB_FETCH_CHARACTER_LIMIT` | `web_fetch_character_limit` | Maximum characters from web page content | `100000` |
| `SWARM_SDK_GLOB_RESULT_LIMIT` | `glob_result_limit` | Maximum file paths returned by Glob tool | `1000` |

---

## Storage Limits

Limits for persistent storage.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_SCRATCHPAD_ENTRY_SIZE_LIMIT` | `scratchpad_entry_size_limit` | Maximum size for single scratchpad entry in bytes | `3000000` (3 MB) |
| `SWARM_SDK_SCRATCHPAD_TOTAL_SIZE_LIMIT` | `scratchpad_total_size_limit` | Maximum total scratchpad storage in bytes | `100000000000` (100 GB) |

---

## Context Management

Settings for context management and optimization.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_CONTEXT_COMPRESSION_THRESHOLD` | `context_compression_threshold` | Context usage percentage triggering compression warning | `60` |
| `SWARM_SDK_TODOWRITE_REMINDER_INTERVAL` | `todowrite_reminder_interval` | Message count between TodoWrite reminders | `8` |
| `SWARM_SDK_CHARS_PER_TOKEN_PROSE` | `chars_per_token_prose` | Characters per token for prose text estimation | `4.0` |
| `SWARM_SDK_CHARS_PER_TOKEN_CODE` | `chars_per_token_code` | Characters per token for code estimation | `3.5` |

---

## Logging

Logging configuration settings.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_MCP_LOG_LEVEL` | `mcp_log_level` | Log level for MCP client (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR) | `2` (WARN) |

---

## WebFetch LLM Processing

Settings for WebFetch tool's optional LLM content processing.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_WEBFETCH_PROVIDER` | `webfetch_provider` | LLM provider for WebFetch content processing | `nil` |
| `SWARM_SDK_WEBFETCH_MODEL` | `webfetch_model` | LLM model for WebFetch content processing | `nil` |
| `SWARM_SDK_WEBFETCH_BASE_URL` | `webfetch_base_url` | Custom API endpoint for WebFetch LLM | `nil` |
| `SWARM_SDK_WEBFETCH_MAX_TOKENS` | `webfetch_max_tokens` | Maximum tokens for WebFetch LLM responses | `4096` |

**Note:** WebFetch LLM processing is enabled when both `webfetch_provider` and `webfetch_model` are configured. When enabled, the `prompt` parameter is required when calling WebFetch.

---

## LLM Response Behavior

Control how LLM API responses are delivered.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_STREAMING` | `streaming` | Enable real-time content delivery via streaming (prevents timeouts) | `true` |

**Benefits of Streaming (enabled by default):**
- Prevents HTTP timeout errors on long responses
- Enables real-time UI updates via `content_chunk` events
- Better UX (users see progress immediately)

**When to Disable:**
- Fast models where streaming overhead isn't needed
- Batch processing without real-time requirements
- Testing with WebMock (doesn't support SSE)

**Per-Agent Override:**
```ruby
agent :backend do
  streaming false  # Override global setting
end
```

**Boolean Environment Variable Values:**
- True: `true`, `yes`, `1`, `on`, `enabled`
- False: `false`, `no`, `0`, `off`, `disabled`

---

## Security Settings

Security-related configuration options.

| Environment Variable | Config Key | Description | Default |
|---------------------|------------|-------------|---------|
| `SWARM_SDK_ALLOW_FILESYSTEM_TOOLS` | `allow_filesystem_tools` | Global toggle to enable/disable filesystem tools (Read, Write, Edit, Glob, Grep) | `true` |
| `SWARM_SDK_ENV_INTERPOLATION` | `env_interpolation` | Global toggle to enable/disable environment variable interpolation in YAML configs | `true` |

**Boolean Environment Variable Values:**
- True: `true`, `yes`, `1`, `on`, `enabled`
- False: `false`, `no`, `0`, `off`, `disabled`

---

## YAML Environment Variable Interpolation

YAML configurations support environment variable interpolation using the `${VAR}` and `${VAR:=default}` syntax. This feature can be controlled globally or per-load.

### Interpolation Syntax

```yaml
# Required variable (raises error if not set)
model: ${OPENAI_MODEL}

# Variable with default value
model: ${OPENAI_MODEL:=gpt-4}

# Empty default
api_key: ${OPTIONAL_KEY:=}
```

### Disabling Interpolation

**Per-load** (highest priority):
```ruby
# Disable for a specific load
swarm = SwarmSDK.load(yaml_content, env_interpolation: false)
swarm = SwarmSDK.load_file("config.yml", env_interpolation: false)
```

**Globally** (via configuration):
```ruby
SwarmSDK.configure do |config|
  config.env_interpolation = false
end
```

**Globally** (via environment variable):
```bash
export SWARM_SDK_ENV_INTERPOLATION=false
```

### Priority Order

1. Per-load parameter (`env_interpolation:`) - highest priority
2. Global config (`SwarmSDK.config.env_interpolation`)
3. Environment variable (`SWARM_SDK_ENV_INTERPOLATION`)
4. Default (`true`) - lowest priority

---

## Examples

### Minimal Configuration (ENV only)

```bash
# .env
OPENAI_API_KEY=sk-...
```

```ruby
require "swarm_sdk"

# No explicit configuration needed - lazy loads from ENV
swarm = SwarmSDK.build do
  name "My Swarm"
  lead :assistant
  agent :assistant do
    description "General assistant"
    prompt "You are helpful"
  end
end
```

### Full Configuration

```ruby
SwarmSDK.configure do |config|
  # API Keys
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]

  # Agent Defaults
  config.default_model = "claude-sonnet-4"
  config.default_provider = "anthropic"
  config.agent_request_timeout = 600

  # Concurrency
  config.global_concurrency_limit = 100
  config.local_concurrency_limit = 20

  # Timeouts
  config.bash_command_timeout = 180_000
  config.web_fetch_timeout = 60

  # Limits
  config.output_character_limit = 50_000
  config.read_max_tokens = 50_000

  # WebFetch LLM
  config.webfetch_provider = "openai"
  config.webfetch_model = "gpt-4o-mini"
  config.webfetch_max_tokens = 8192

  # Security
  config.allow_filesystem_tools = true
end
```

### Testing Configuration

```ruby
# test/test_helper.rb
def setup
  SwarmSDK.reset_config!
end

def teardown
  SwarmSDK.reset_config!
end

# test/my_test.rb
def test_with_custom_config
  SwarmSDK.configure do |config|
    config.openai_api_key = "test-key"
    config.agent_request_timeout = 60
  end

  # Test code here
end
```

---

## See Also

- [Ruby DSL Reference](ruby-dsl.md) - Programmatic swarm building
- [YAML Configuration](yaml-configuration.md) - YAML-based swarm definitions
- [Changelog](../CHANGELOG.swarm_sdk.md) - Version history and breaking changes
