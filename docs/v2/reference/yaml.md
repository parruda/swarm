# YAML Configuration Reference

Complete YAML configuration reference for SwarmSDK v2.

---

## Document Structure

SwarmSDK v2 configurations support two types, distinguished by the root key:

### Simple Swarm (Multi-Agent Collaboration)

```yaml
version: 2
swarm:                    # Use 'swarm:' key for swarms
  name: "Development Team"
  lead: backend           # Required for swarms
  agents:
    backend:
      # Agent configuration
    tester:
      # Agent configuration
```

**Returns:** `SwarmSDK::Swarm` when loaded with `SwarmSDK.load_file`

### Workflow (Multi-Stage Pipeline)

```yaml
version: 2
workflow:                 # Use 'workflow:' key for workflows
  name: "Build Pipeline"
  start_node: planning    # Required for workflows
  agents:
    architect:
      # Agent configuration
    coder:
      # Agent configuration
  nodes:                  # Required for workflows
    planning:
      agents:
        - agent: architect
    implementation:
      agents:
        - agent: coder
      dependencies:
        - planning
```

**Returns:** `SwarmSDK::Workflow` when loaded with `SwarmSDK.load_file`

**Type Detection:**
- `swarm:` key → Creates `SwarmSDK::Swarm` (requires `lead:`, cannot have `nodes:`)
- `workflow:` key → Creates `SwarmSDK::Workflow` (requires `start_node:` and `nodes:`)
- Cannot have both `swarm:` and `workflow:` keys in same file
- Same `SwarmSDK.load_file` API works for both types!

---

## Top-Level Fields

### version

**Type:** Integer (required)
**Value:** `2`
**Description:** Configuration version number. Must be `2` for SwarmSDK v2.

```yaml
version: 2
```

---

### swarm

**Type:** Object (required for Swarm type)
**Description:** Root configuration object for multi-agent collaboration swarms. Use this key when you want agents to collaborate through delegation.

**Mutually exclusive with:** `workflow:`

```yaml
swarm:
  name: "Development Team"
  lead: backend
  agents:
    # ...
```

---

### workflow

**Type:** Object (required for Workflow type)
**Description:** Root configuration object for multi-stage pipeline workflows. Use this key when you want to orchestrate agents through sequential or parallel nodes.

**Mutually exclusive with:** `swarm:`

```yaml
workflow:
  name: "Build Pipeline"
  start_node: planning
  agents:
    # ...
  nodes:
    # ...
```

---

## Swarm Configuration

Fields under the `swarm` key (for Swarm type configurations).

### id

**Type:** String (optional)
**Description:** Unique swarm identifier.

**When required:**
- **Required** when using composable swarms (`swarms:` section)
- **Optional** otherwise (auto-generates if omitted)

**Purpose:**
- Hierarchical swarm tracking in events (`swarm_id`, `parent_swarm_id`)
- Building parent/child relationships in composable swarms
- Identifying swarms in logs and monitoring

If omitted and not using composable swarms, an ID is auto-generated from the swarm name with a random suffix.

```yaml
swarm:
  id: development_team
  id: code_review_v2
  id: main_app
```

---

### name

**Type:** String (required)
**Description:** Human-readable swarm name.

```yaml
swarm:
  name: "Development Team"
  name: "Code Review Swarm"
```

---

### swarms

**Type:** Object (optional)
**Description:** External swarms to register for composable swarms feature.
**Format:** `{ swarm_name: swarm_config }`

**Enables delegation to other swarms as if they were agents.** A swarm IS an agent - delegating to a child swarm is identical to delegating to an agent. The child swarm's lead agent serves as its public interface.

**Configuration per swarm:**
- `file` (String): Path to swarm file (.rb or .yml)
- `yaml` (String): YAML configuration content (for dynamic loading)
- `swarm` (Object): Inline swarm definition
- `keep_context` (Boolean, optional): Preserve conversation (default: true)

**Rules:**
- Exactly ONE of `file`, `yaml`, or `swarm` must be provided
- `id` must be set on parent swarm when using `swarms:`

**Example - From Files:**
```yaml
swarm:
  id: main_app
  name: "Main Application"
  lead: backend

  swarms:
    code_review:
      file: "./swarms/code_review.rb"
      keep_context: true

    testing:
      file: "./swarms/testing.yml"
      keep_context: false

  agents:
    backend:
      delegates_to:
        - code_review
        - testing
```

**Example - Inline Definition:**
```yaml
swarm:
  id: main_app
  name: "Main Application"
  lead: backend

  swarms:
    # File reference
    code_review:
      file: "./swarms/code_review.rb"

    # Inline definition - no file needed!
    testing:
      keep_context: false
      swarm:
        id: testing_team
        name: "Testing Team"
        lead: tester
        agents:
          tester:
            description: "Test specialist"
            model: gpt-4o-mini
            system: "You test code"
            tools:
              - Think
              - Bash

  agents:
    backend:
      description: "Backend developer"
      delegates_to:
        - code_review
        - testing
```

**Hierarchical IDs:**
Sub-swarms automatically get hierarchical IDs:
- Parent swarm: `main_app`
- Sub-swarms: `main_app/code_review`, `main_app/testing`

**Keep Context:**
- `keep_context: true` (default): Swarm maintains conversation history
- `keep_context: false`: Swarm context resets after each delegation

---

### lead

**Type:** String (required)
**Description:** Name of the lead agent (entry point for execution).

```yaml
swarm:
  lead: backend
  lead: coordinator
```

---

### scratchpad

**Type:** Symbol/String (optional)
**Default:** `disabled`
**Description:** Configure scratchpad mode for the swarm or workflow.

**Valid Values:**
- For regular Swarms: `enabled`, `disabled`
- For workflows with nodes: `enabled`, `per_node`, `disabled`

**Modes:**
- **`enabled`**: Scratchpad tools available (ScratchpadWrite, ScratchpadRead, ScratchpadList)
  - Regular Swarm: All agents share one scratchpad
  - With nodes: All nodes share one scratchpad across workflow
- **`per_node`**: (Nodes only) Each node gets isolated scratchpad storage
- **`disabled`**: No scratchpad tools available

Scratchpad is volatile (in-memory only) and provides temporary storage for cross-agent or cross-node communication.

```yaml
# Regular swarm
swarm:
  scratchpad: enabled   # enable scratchpad
  scratchpad: disabled  # no scratchpad (default)

# Workflow - shared across all nodes
workflow:
  scratchpad: enabled
  start_node: planning
  nodes:
    planning: { ... }
    implementation: { ... }

# Workflow - isolated per node
workflow:
  scratchpad: per_node
  start_node: planning
  nodes:
    planning: { ... }
    implementation: { ... }
```

---

### agents

**Type:** Object (required)
**Description:** Map of agent names to agent configurations.
**Format:** `{ agent_name: agent_config }`

```yaml
swarm:
  agents:
    backend:
      description: "Backend developer"
      model: gpt-5
      tools: [Read, Write, Bash]

    frontend:
      description: "Frontend developer"
      model: claude-sonnet-4
      tools: [Read, Write]
```

---

### all_agents

**Type:** Object (optional)
**Description:** Configuration applied to all agents. Agent-specific values override these defaults.
**Default:** `{}`

```yaml
swarm:
  all_agents:
    provider: openai
    timeout: 180
    tools: [Read, Write]
    coding_agent: false

    permissions:
      Write:
        denied_paths: ["secrets/**"]
```

---

### hooks

**Type:** Object (optional)
**Description:** Swarm-level hooks (swarm_start and swarm_stop only).
**Default:** `{}`

```yaml
swarm:
  hooks:
    swarm_start:
      - type: command
        command: "echo 'Starting swarm' >> log.txt"

    swarm_stop:
      - type: command
        command: "scripts/cleanup.sh"
        timeout: 30
```

---

### nodes

**Type:** Object (required for Workflow type)
**Description:** Map of node names to node configurations. Enables multi-stage workflows with multiple execution stages.
**Format:** `{ node_name: node_config }`

**Important:** This field is only valid under the `workflow:` key, not `swarm:`.

Nodes allow you to create workflows where different agent teams collaborate in sequence. Each node is an independent swarm execution that can receive input from previous nodes and pass output to subsequent nodes.

**Example:**
```yaml
workflow:
  name: "Build Pipeline"
  start_node: planning
  agents:
    architect: { ... }
    backend: { ... }
    tester: { ... }
    reviewer: { ... }

  nodes:
    planning:
      agents:
        - agent: architect
      output_command: "tee plan.txt"

    implementation:
      agents:
        - agent: backend
          delegates_to: [tester]
          tools: [Read, Edit, Write]  # Override tools for this node
        - agent: tester
      dependencies: [planning]
      input_command: "cat plan.txt"

    review:
      agents:
        - agent: reviewer
      dependencies: [implementation]
```

**Node configuration fields:**
- `agents` - Array of agent configurations (optional for computation-only nodes)
- `dependencies` - Array of prerequisite node names
- `lead` - Override the lead agent for this node
- `input_command` - Bash command to transform input before execution
- `input_timeout` - Timeout for input_command (seconds, default: 60)
- `output_command` - Bash command to transform output after execution
- `output_timeout` - Timeout for output_command (seconds, default: 60)

**Per-node agent configuration:**
Each agent in a node's `agents` array can have:
- `agent` (required) - Agent name (must be defined in global `agents` section)
- `delegates_to` (optional) - Override delegation targets for this node
- `reset_context` (optional) - Whether to reset context (default: true)
- `tools` (optional) - Override tools for this node (replaces global agent tools)

```yaml
nodes:
  planning:
    agents:
      - agent: backend
        tools: [Read, Think]  # Restrict to read-only + reasoning in planning

  implementation:
    agents:
      - agent: backend
        delegates_to: [tester]
        tools: [Read, Edit, Write, Bash]  # Full tools in implementation
```

---

### start_node

**Type:** String (required for Workflow type)
**Description:** Name of the starting node for workflow execution.

**Important:** This field is only valid under the `workflow:` key, not `swarm:`.

**Example:**
```yaml
workflow:
  name: "Dev Workflow"
  start_node: planning  # Required: Start with planning node
  agents:
    coordinator:
      description: "Coordinator"
      model: "gpt-5"
    backend:
      description: "Backend dev"
      model: "gpt-5"
  nodes:
    planning:
      agents:
        - agent: coordinator
    implementation:
      agents:
        - agent: backend
      dependencies: [planning]
```

---

## Agent Configuration

Fields under each agent in `swarm.agents`.

### description

**Type:** String (required)
**Description:** Human-readable description of the agent's role.

```yaml
agents:
  backend:
    description: "Backend API developer specializing in Ruby on Rails"
  frontend:
    description: "Frontend developer with React and TypeScript expertise"
```

---

### model

**Type:** String (optional)
**Default:** `"gpt-5"`
**Description:** LLM model identifier.

**Common models:**
- OpenAI: `gpt-5`, `gpt-4o`, `o4`, `o4-mini`
- Anthropic: `claude-sonnet-4`, `claude-opus-4`
- Google: `gemini-2.5-flash`, `gemini-2.0-pro`
- DeepSeek: `deepseek-chat`, `deepseek-reasoner`

```yaml
agents:
  backend:
    model: gpt-5
  frontend:
    model: claude-sonnet-4
  analyzer:
    model: deepseek-reasoner
```

---

### provider

**Type:** String (optional)
**Default:** `"openai"`
**Description:** LLM provider name.

**Supported providers:**
- `openai`: OpenAI
- `anthropic`: Anthropic Claude
- `google`: Google AI
- `deepseek`: DeepSeek
- `openrouter`: OpenRouter
- `mistral`: Mistral AI
- `perplexity`: Perplexity

```yaml
agents:
  backend:
    provider: openai
  frontend:
    provider: anthropic
```

---

### base_url

**Type:** String (optional)
**Default:** Provider's default endpoint
**Description:** Custom API endpoint URL (for proxies or compatible APIs).
**Auto-sets:** `assume_model_exists: true`

```yaml
agents:
  backend:
    base_url: "http://localhost:8080/v1"
  frontend:
    base_url: "https://proxy.example.com/v1"
```

---

### api_version

**Type:** String (optional)
**Default:** `"v1/chat/completions"`
**Description:** API version for OpenAI-compatible providers.

**Valid values:**
- `v1/chat/completions`: Standard chat completions (default)
- `v1/responses`: Extended responses format

**Compatible providers:** `openai`, `deepseek`, `perplexity`, `mistral`, `openrouter`

```yaml
agents:
  backend:
    provider: openai
    api_version: "v1/chat/completions"

  reasoner:
    provider: deepseek
    api_version: "v1/responses"
```

---

### directory

**Type:** String (optional)
**Default:** `"."`
**Description:** Agent's working directory. All file operations are relative to this path.

```yaml
agents:
  backend:
    directory: "."
  frontend:
    directory: "frontend"
  docs:
    directory: "/absolute/path/to/docs"
```

---

### system_prompt

**Type:** String (optional)
**Default:** `nil`
**Description:** Custom system prompt text.

**Combination with `coding_agent`:**
- `coding_agent: false` (default): Uses only custom prompt + TODO/Scratchpad info
- `coding_agent: true`: Prepends base coding prompt, then custom prompt

```yaml
agents:
  backend:
    system_prompt: "You are a backend API developer. Focus on clean, testable code."

  reviewer:
    system_prompt: |
      You are a code reviewer. For each file:
      1. Check for bugs and edge cases
      2. Suggest improvements
      3. Verify test coverage
```

---

### coding_agent

**Type:** Boolean (optional)
**Default:** `false`
**Description:** Whether to include the base coding system prompt.

**Behavior:**
- `false`: Uses only custom `system_prompt` + TODO/Scratchpad sections
- `true`: Prepends comprehensive base coding prompt, then custom prompt

```yaml
agents:
  developer:
    coding_agent: true   # Include base coding prompt
  analyst:
    coding_agent: false  # Custom prompt only (default)
```

---

### tools

**Type:** Array (optional)
**Default:** Default tools if `default tools enabled`
**Description:** List of tools available to the agent.

**Default tools (when `default tools enabled`):**
- `Read`, `Glob`, `Grep`, `TodoWrite`, `Think`, `WebFetch`

**Scratchpad tools** (opt-in via `scratchpad: enabled` at swarm level):
- `ScratchpadWrite`, `ScratchpadRead`, `ScratchpadList`

**Memory tools** (added if agent has `memory` configured):
- `MemoryWrite`, `MemoryRead`, `MemoryEdit`, `MemoryMultiEdit`, `MemoryGlob`, `MemoryGrep`, `MemoryDelete`

**Additional tools:**
- `Write`, `Edit`, `MultiEdit`, `Bash`

**Format:** Simple array or array of objects with permissions

```yaml
# Simple format
agents:
  backend:
    tools: [Read, Write, Edit, Bash]

# With inline permissions
agents:
  backend:
    tools:
      - Read
      - Write:
          allowed_paths: ["backend/**/*"]
          denied_paths: ["backend/secrets/**"]
      - Bash:
          allowed_commands: ["^git (status|diff|log)$"]
          denied_commands: ["^rm -rf"]

# Without default tools
agents:
  minimal:
    tools: [Read, Write]
    disable_default_tools: true
```

---

### delegates_to

**Type:** Array (optional)
**Default:** `[]`
**Description:** List of agent names this agent can delegate to.

**Behavior:** Creates a `delegate_to_{agent}` tool for each target

```yaml
agents:
  backend:
    delegates_to: [database, tester]
  coordinator:
    delegates_to: [frontend, backend, reviewer]
```

---

### shared_across_delegations

**Type:** Boolean (optional)
**Default:** `false`
**Description:** Control whether multiple agents share the same instance when delegating to this agent.

**Values:**
- `false` (default): Create isolated instances per delegator (recommended)
- `true`: Share the same instance across all delegators

**Behavior:**

By default, when multiple agents delegate to the same target, each gets its own isolated instance with separate conversation history. This prevents context mixing.

**Isolated Mode Example (default):**
```yaml
agents:
  tester:
    description: "Testing agent"
    # shared_across_delegations: false (default)

  frontend:
    delegates_to: [tester]  # Gets tester@frontend

  backend:
    delegates_to: [tester]  # Gets tester@backend (separate)
```

**Shared Mode Example (opt-in):**
```yaml
agents:
  database:
    description: "Database coordination agent"
    shared_across_delegations: true  # All delegators share this

  frontend:
    delegates_to: [database]  # Gets shared database primary

  backend:
    delegates_to: [database]  # Gets same shared database
```

**Memory Sharing:**

Plugin storage (like SwarmMemory) is always shared by base agent name:
- `tester@frontend` and `tester@backend` share memory storage
- Only conversation history and tool state are isolated

**When to use:**
- **Shared mode**: Stateful coordination, database agents, shared context needs
- **Isolated mode (default)**: Testing different codebases, reviewing different PRs, preventing context mixing

---

### memory

**Type:** Object (optional)
**Default:** `null` (memory disabled)
**Description:** Configure persistent memory storage for this agent.

When configured, the agent automatically gets all 7 memory tools (MemoryWrite, MemoryRead, MemoryEdit, MemoryMultiEdit, MemoryGlob, MemoryGrep, MemoryDelete) and a memory system prompt is appended.

Memory is per-agent (isolated) and persistent (survives across sessions).

**Fields:**
- `adapter` (String, optional): Storage adapter (default: `"filesystem"`)
- `directory` (String, required): Directory where `memory.json` will be stored

```yaml
agents:
  learning_assistant:
    description: "Assistant that learns"
    model: gpt-4
    memory:
      adapter: filesystem  # optional
      directory: .swarm/assistant-memory  # required

  # Minimal (adapter defaults to filesystem)
  another_agent:
    memory:
      directory: .swarm/another-agent
```

**Future adapters:** `sqlite`, `faiss` (not yet implemented)

---

### mcp_servers

**Type:** Array (optional)
**Default:** `[]`
**Description:** MCP server configurations for this agent.

**Transport types:** `stdio`, `sse`, `http`

```yaml
agents:
  backend:
    mcp_servers:
      # stdio transport
      - name: filesystem
        type: stdio
        command: npx
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/allowed/path"]
        env:
          VAR: value

      # SSE transport
      - name: web
        type: sse
        url: "https://example.com/mcp"
        headers:
          authorization: "Bearer token"
        timeout: 60

      # HTTP transport
      - name: api
        type: http
        url: "https://api.example.com/mcp"
        headers:
          api-key: "key"
        timeout: 120
```

---

### permissions

**Type:** Object (optional)
**Default:** `{}`
**Description:** Tool permission configuration. Uses glob patterns for paths, regex for commands.

**Format:** `{ ToolName: { allowed_paths, denied_paths, allowed_commands, denied_commands } }`

```yaml
agents:
  backend:
    permissions:
      Write:
        allowed_paths:
          - "backend/**/*"
          - "shared/**/*"
        denied_paths:
          - "backend/secrets/**"
          - "shared/config/credentials.yml"

      Read:
        denied_paths:
          - "*.key"
          - ".env"

      Bash:
        allowed_commands:
          - "^git (status|diff|log)$"
          - "^bundle exec rspec$"
        denied_commands:
          - "^rm -rf"
          - "^sudo"
```

---

### hooks

**Type:** Object (optional)
**Default:** `{}`
**Description:** Agent-specific hooks configuration.

**Event types:**
- `pre_tool_use`: Before tool execution
- `post_tool_use`: After tool execution
- `user_prompt`: Before sending user message
- `agent_stop`: When agent finishes
- `first_message`: First user message (once per swarm)
- `pre_delegation`: Before delegating to another agent
- `post_delegation`: After delegation completes
- `context_warning`: When context window threshold exceeded

```yaml
agents:
  backend:
    hooks:
      pre_tool_use:
        - matcher: "Write|Edit"
          type: command
          command: "scripts/validate.sh"
          timeout: 10

      post_tool_use:
        - matcher: "Bash"
          type: command
          command: "logger 'Command executed'"

      user_prompt:
        - type: command
          command: "scripts/log-request.sh"
```

---

### parameters

**Type:** Object (optional)
**Default:** `{}`
**Description:** LLM parameters (temperature, top_p, etc.).

**Common parameters:**
- `temperature` (Float): Randomness (0.0-2.0)
- `top_p` (Float): Nucleus sampling (0.0-1.0)
- `max_tokens` (Integer): Maximum output tokens
- `presence_penalty` (Float): Presence penalty (-2.0-2.0)
- `frequency_penalty` (Float): Frequency penalty (-2.0-2.0)

```yaml
agents:
  creative:
    parameters:
      temperature: 0.9
      top_p: 0.95

  precise:
    parameters:
      temperature: 0.3
      max_tokens: 2000
```

---

### headers

**Type:** Object (optional)
**Default:** `{}`
**Description:** Custom HTTP headers for API requests.

```yaml
agents:
  backend:
    headers:
      X-API-Key: "key123"
      X-Organization: "org123"
      Authorization: "Bearer token"
```

---

### timeout

**Type:** Integer (optional)
**Default:** `300` (5 minutes)
**Description:** Request timeout in seconds.

```yaml
agents:
  fast:
    timeout: 60

  reasoning:
    timeout: 600  # 10 minutes for reasoning models
```

---

### context_window

**Type:** Integer (optional)
**Default:** Auto-detected from model registry
**Description:** Explicit context window size in tokens.

**Use case:** Override when using custom models or proxies

```yaml
agents:
  custom:
    model: custom-model
    context_window: 128000  # Override auto-detection
```

---

### bypass_permissions

**Type:** Boolean (optional)
**Default:** `false`
**Description:** Disable permission checks for this agent.

**Warning:** Use with caution - allows unrestricted file/command access

```yaml
agents:
  admin:
    bypass_permissions: true  # Disable all permission checks
```

---

### max_concurrent_tools

**Type:** Integer (optional)
**Default:** Swarm's `default_local_concurrency` (10)
**Description:** Maximum concurrent tool calls for this agent.

```yaml
agents:
  parallel:
    max_concurrent_tools: 20  # Allow more parallelism

  sequential:
    max_concurrent_tools: 1   # Force sequential execution
```

---

### disable_default_tools

**Type:** Boolean (optional)
**Default:** `true`
**Description:** Include default tools (Read, Grep, Glob, and scratchpad tools).

```yaml
agents:
  minimal:
    tools: [Bash]
    disable_default_tools: true  # No default tools
```

---

### assume_model_exists

**Type:** Boolean (optional)
**Default:** `false` (validate), `true` when `base_url` is set
**Description:** Skip model validation for custom models.

```yaml
agents:
  custom:
    model: my-custom-model
    base_url: "https://my-proxy.com/v1"
    assume_model_exists: true  # Skip validation
```

---

### agent_file

**Type:** String (optional)
**Default:** `nil`
**Description:** Path to markdown file containing agent configuration (system prompt and tools).

**Format:** Path relative to YAML file or absolute

```yaml
agents:
  backend:
    description: "Backend developer"
    agent_file: "agents/backend.md"

  frontend:
    description: "Frontend developer"
    agent_file: "/absolute/path/to/frontend.md"
```

**Markdown file format** (requires YAML frontmatter):
```markdown
---
description: "Backend developer"
model: "gpt-4"
tools:
  - Read
  - Write
  - Edit
  - Bash
---

You are a backend API developer specializing in Ruby on Rails.

Focus on clean, testable code with proper error handling.
```

---

## All-Agents Configuration

Fields under `swarm.all_agents`. All fields are optional and provide defaults for agents.

### model

**Type:** String
**Description:** Default model for all agents.

```yaml
swarm:
  all_agents:
    model: gpt-5
```

---

### provider

**Type:** String
**Description:** Default provider for all agents.

```yaml
swarm:
  all_agents:
    provider: anthropic
```

---

### base_url

**Type:** String
**Description:** Default base URL for all agents.

```yaml
swarm:
  all_agents:
    base_url: "https://proxy.example.com/v1"
```

---

### api_version

**Type:** String
**Description:** Default API version for all agents.

```yaml
swarm:
  all_agents:
    api_version: "v1/responses"
```

---

### timeout

**Type:** Integer
**Description:** Default timeout for all agents.

```yaml
swarm:
  all_agents:
    timeout: 180
```

---

### parameters

**Type:** Object
**Description:** Default LLM parameters for all agents.

```yaml
swarm:
  all_agents:
    parameters:
      temperature: 0.7
      max_tokens: 2000
```

---

### headers

**Type:** Object
**Description:** Default HTTP headers for all agents.

```yaml
swarm:
  all_agents:
    headers:
      X-Organization: "org123"
```

---

### coding_agent

**Type:** Boolean
**Description:** Default coding_agent flag for all agents.

```yaml
swarm:
  all_agents:
    coding_agent: false
```

---

### tools

**Type:** Array
**Description:** Tools that all agents will have (in addition to agent-specific tools).

```yaml
swarm:
  all_agents:
    tools: [Read, Write]
```

---

### permissions

**Type:** Object
**Description:** Default permissions for all agents.

```yaml
swarm:
  all_agents:
    permissions:
      Write:
        denied_paths: ["secrets/**"]
      Bash:
        denied_commands: ["^rm -rf", "^sudo"]
```

---

### hooks

**Type:** Object
**Description:** Hooks applied to all agents.

**Valid events:** All agent-level events (not swarm-level events)

```yaml
swarm:
  all_agents:
    hooks:
      pre_tool_use:
        - matcher: "Write"
          type: command
          command: "scripts/validate-write.sh"
```

---

## Hooks Configuration

### Hook Structure

Each hook is an object with the following fields:

#### type

**Type:** String (required)
**Value:** `"command"`
**Description:** Hook type. Only `command` supported in YAML (Ruby DSL supports blocks).

```yaml
hooks:
  pre_tool_use:
    - type: command
      command: "validate.sh"
```

---

#### command

**Type:** String (required for type: command)
**Description:** Shell command to execute.

**Environment variables available:**
- `SWARM_NAME`: Swarm name
- `AGENT_NAME`: Current agent name
- `HOOK_EVENT`: Event type (pre_tool_use, post_tool_use, etc.)
- `TOOL_NAME`: Tool name (for tool events)

```yaml
hooks:
  pre_tool_use:
    - type: command
      command: "scripts/validate.sh"
      command: "npx eslint $FILE_PATH"
```

---

#### matcher

**Type:** String (optional)
**Description:** Tool name pattern (regex) for filtering (tool events only).

```yaml
hooks:
  pre_tool_use:
    # Match Write or Edit
    - matcher: "Write|Edit"
      type: command
      command: "validate.sh"

    # Match all Bash commands
    - matcher: "Bash"
      type: command
      command: "log-command.sh"
```

---

#### timeout

**Type:** Integer (optional)
**Default:** `60`
**Description:** Command timeout in seconds.

```yaml
hooks:
  pre_tool_use:
    - type: command
      command: "slow-validation.sh"
      timeout: 120
```

---

### Hook Events

#### swarm_start

Fires when swarm execution begins (before first message).

**Available in:** `swarm.hooks` only (not agent hooks)

**Input (stdin JSON):**
```json
{
  "event": "swarm_start",
  "prompt": "User's task prompt",
  "swarm_name": "Development Team",
  "lead_agent": "backend",
  "timestamp": "2024-01-01T12:00:00Z"
}
```

**Exit codes:**
- `0`: Success, continue execution (stdout appended to prompt if non-empty)
- `2`: Halt execution with error message from stderr
- Other: Non-blocking warning (stderr logged, execution continues)

```yaml
swarm:
  hooks:
    swarm_start:
      - type: command
        command: "scripts/pre-flight-check.sh"
```

---

#### swarm_stop

Fires when swarm execution completes.

**Available in:** `swarm.hooks` only (not agent hooks)

**Input (stdin JSON):**
```json
{
  "event": "swarm_stop",
  "swarm_name": "Development Team",
  "lead_agent": "backend",
  "last_agent": "backend",
  "content": "Final response",
  "success": true,
  "duration": 5.2,
  "total_cost": 0.0045,
  "total_tokens": 1234,
  "agents_involved": ["backend", "frontend"],
  "timestamp": "2024-01-01T12:00:05Z"
}
```

**Exit codes:**
- `0`: Success, stdout can trigger reprompt
- `1`: Log error but continue
- `2`: Halt with error

**Reprompt:** If stdout is non-empty, reprompt the lead agent with stdout content

```yaml
swarm:
  hooks:
    swarm_stop:
      - type: command
        command: "scripts/post-execution.sh"
```

---

#### pre_tool_use

Fires before tool execution.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "pre_tool_use",
  "agent": "backend",
  "tool": "Write",
  "parameters": {
    "file_path": "src/app.rb",
    "content": "..."
  }
}
```

**Exit codes:**
- `0`: Continue execution
- `2`: Halt tool execution with error message from stderr
- Other: Non-blocking warning (stderr logged, execution continues)

```yaml
agents:
  backend:
    hooks:
      pre_tool_use:
        - matcher: "Write|Edit"
          type: command
          command: "scripts/validate-write.sh"
```

---

#### post_tool_use

Fires after tool execution.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "post_tool_use",
  "agent": "backend",
  "tool": "Write",
  "result": "File written successfully",
  "success": true
}
```

**Exit codes:**
- `0`: Continue execution
- `2`: Halt execution with error message from stderr
- Other: Non-blocking warning (stderr logged, execution continues)

```yaml
agents:
  backend:
    hooks:
      post_tool_use:
        - matcher: "Bash"
          type: command
          command: "logger 'Command executed'"
```

---

#### user_prompt

Fires before sending user message to LLM.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "user_prompt",
  "agent": "backend",
  "prompt": "Build a REST API",
  "model": "gpt-5",
  "provider": "openai",
  "message_count": 1
}
```

```yaml
agents:
  backend:
    hooks:
      user_prompt:
        - type: command
          command: "scripts/log-request.sh"
```

---

#### agent_stop

Fires when agent finishes execution.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "agent_stop",
  "agent": "backend",
  "model": "gpt-5",
  "content": "Here is the implementation...",
  "finish_reason": "stop",
  "usage": {
    "input_tokens": 234,
    "output_tokens": 567,
    "total_tokens": 801,
    "total_cost": 0.0023
  }
}
```

```yaml
agents:
  backend:
    hooks:
      agent_stop:
        - type: command
          command: "scripts/log-response.sh"
```

---

#### first_message

Fires on first user message (once per swarm execution).

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "first_message",
  "agent": "backend",
  "prompt": "Build a REST API",
  "swarm_name": "Development Team",
  "timestamp": "2024-01-01T12:00:00Z"
}
```

```yaml
all_agents:
  hooks:
    first_message:
      - type: command
        command: "scripts/initialize.sh"
```

---

#### pre_delegation

Fires before delegating to another agent.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "pre_delegation",
  "agent": "backend",
  "delegation_target": "database",
  "prompt": "Create the users table"
}
```

```yaml
agents:
  backend:
    hooks:
      pre_delegation:
        - type: command
          command: "echo 'Delegating to $DELEGATION_TARGET'"
```

---

#### post_delegation

Fires after delegation completes.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "post_delegation",
  "agent": "backend",
  "delegation_target": "database",
  "result": "Table created successfully"
}
```

```yaml
agents:
  backend:
    hooks:
      post_delegation:
        - type: command
          command: "logger 'Delegation complete'"
```

---

#### context_warning

Fires when context window threshold exceeded.

**Available in:** `swarm.agents.{agent}.hooks`, `swarm.all_agents.hooks`

**Input (stdin JSON):**
```json
{
  "event": "context_warning",
  "agent": "backend",
  "model": "gpt-5",
  "threshold": "80%",
  "percentage": "85%",
  "tokens_used": 102400,
  "tokens_remaining": 25600,
  "context_limit": 128000
}
```

```yaml
agents:
  backend:
    hooks:
      context_warning:
        - type: command
          command: "notify-admin.sh"
```

---

## Node Configuration

Fields under each node in `workflow.nodes`.

### agents

**Type:** Array (optional)
**Default:** `[]`
**Description:** List of agents participating in this node.

Nodes can have zero agents (computation-only nodes with transformers) or multiple agents working together. Each agent can have delegation configured and context preservation settings.

**Format:** Array of objects with `agent`, optional `delegates_to`, and optional `reset_context`

```yaml
nodes:
  implementation:
    agents:
      - agent: backend
        delegates_to: [tester, database]
      - agent: tester
        delegates_to: [database]
        reset_context: false  # Preserve context from previous nodes
      - agent: database
```

---

### lead

**Type:** String (optional)
**Default:** First agent in `agents` list
**Description:** Lead agent for this node (overrides default first agent).

The lead agent receives the initial prompt and coordinates the node's execution.

```yaml
nodes:
  review:
    agents:
      - agent: backend
      - agent: reviewer
    lead: reviewer  # reviewer leads instead of backend
```

---

### dependencies

**Type:** Array (optional)
**Default:** `[]`
**Description:** List of prerequisite node names that must execute before this node.

Dependencies create a directed acyclic graph (DAG) of node execution. A node waits for all its dependencies to complete before starting.

```yaml
nodes:
  planning:
    agents:
      - agent: architect

  implementation:
    agents:
      - agent: backend
    dependencies: [planning]  # Runs after planning

  testing:
    agents:
      - agent: tester
    dependencies: [implementation]  # Runs after implementation
```

---

### reset_context

**Type:** Boolean (optional, per-agent in node)
**Default:** `true`
**Description:** Whether to reset agent conversation context in this node.

Set to `false` to preserve conversation history from previous nodes, enabling stateful multi-node workflows.

```yaml
nodes:
  first:
    agents:
      - agent: architect

  second:
    agents:
      - agent: architect
        reset_context: false  # Preserve history from first node
    dependencies: [first]
```

---

### input_command

**Type:** String (optional)
**Default:** `nil`
**Description:** Bash command to transform input before node execution.

**Input (stdin):** NodeContext as JSON
**Output (stdout):** Transformed input content

**Exit codes:**
- `0`: Success, use stdout as transformed content
- `1`: Skip node execution, use current_input unchanged
- `2`: Halt workflow with error from stderr

**NodeContext JSON:**
```json
{
  "original_prompt": "User's original prompt",
  "node_name": "implementation",
  "dependencies": ["planning"],
  "content": "Previous node's content",
  "all_results": {
    "planning": {
      "content": "...",
      "agent": "architect",
      "duration": 3.2,
      "success": true
    }
  }
}
```

```yaml
nodes:
  implementation:
    input_command: "scripts/transform-input.sh"
    input_command: "jq '.content'"
    input_command: "scripts/validate.sh"  # Exit 1 to skip, 2 to halt
```

---

### input_timeout

**Type:** Integer (optional)
**Default:** `60`
**Description:** Timeout for input_command in seconds.

```yaml
nodes:
  implementation:
    input_command: "scripts/slow-transform.sh"
    input_timeout: 120
```

---

### output

**Type:** String (optional, Ruby DSL only)
**Description:** Ruby block for output transformation. Not supported in YAML - use `output_command` instead.

---

### output_command

**Type:** String (optional)
**Default:** `nil`
**Description:** Bash command to transform output after node execution.

**Input (stdin):** NodeContext as JSON (with result)
**Output (stdout):** Transformed output content

**Exit codes:**
- `0`: Success, use stdout as transformed content
- `1`: Pass through unchanged, use result.content
- `2`: Halt workflow with error from stderr

**NodeContext JSON:**
```json
{
  "original_prompt": "User's original prompt",
  "node_name": "implementation",
  "content": "Current node's result content",
  "agent": "backend",
  "duration": 5.2,
  "success": true,
  "all_results": {
    "planning": { ... },
    "implementation": { ... }
  }
}
```

```yaml
nodes:
  implementation:
    output_command: "scripts/transform-output.sh"
    output_command: "tee results.txt"
    output_command: "scripts/save-and-format.sh"
```

---

### output_timeout

**Type:** Integer (optional)
**Default:** `60`
**Description:** Timeout for output_command in seconds.

```yaml
nodes:
  implementation:
    output_command: "scripts/slow-format.sh"
    output_timeout: 120
```

---

## Environment Variable Interpolation

SwarmSDK supports environment variable interpolation with default values.

### Syntax

**Simple:**
```yaml
${ENV_VAR}
```

**With default:**
```yaml
${ENV_VAR:=default_value}
```

### Examples

```yaml
swarm:
  agents:
    backend:
      model: ${MODEL}  # Required env var
      base_url: ${BASE_URL:=http://localhost:8080}  # With default
      headers:
        Authorization: "Bearer ${API_TOKEN}"
      parameters:
        temperature: ${TEMPERATURE:=0.7}

      mcp_servers:
        - name: filesystem
          type: stdio
          command: npx
          args: ["-y", "@modelcontextprotocol/server-filesystem", "${ALLOWED_PATH:=.}"]
```

**Shell usage:**
```bash
# With environment variables
MODEL=gpt-5 API_TOKEN=abc123 swarm run config.yml -p "Task"

# With defaults (no env vars set)
swarm run config.yml -p "Task"  # Uses defaults from config
```

---

## Permission Patterns

### Path Patterns (Glob)

Glob patterns for file paths.

**Syntax:**
- `*`: Match any characters except `/`
- `**`: Match any characters including `/`
- `?`: Match single character
- `[abc]`: Match a, b, or c
- `{a,b}`: Match a or b

**Examples:**
```yaml
permissions:
  Write:
    allowed_paths:
      - "backend/**/*"        # All files under backend/
      - "shared/**/*.rb"      # All .rb files under shared/
      - "config/*.yml"        # YAML files in config/ (not subdirs)
      - "**/test_*.rb"        # test_*.rb anywhere
      - "src/{models,views}/**/*"  # models/ and views/ in src/

    denied_paths:
      - "backend/secrets/**"  # No files in secrets/
      - "**/credentials.yml"  # No credentials.yml anywhere
      - "*.key"               # No .key files in root
      - ".env*"               # No .env files
```

---

### Command Patterns (Regex)

Regular expressions for bash commands.

**Syntax:** Standard Ruby/PCRE regex

**Examples:**
```yaml
permissions:
  Bash:
    allowed_commands:
      - "^git (status|diff|log)$"       # Only safe git commands
      - "^bundle exec (rspec|rubocop)$" # Only test/lint
      - "^npm (test|run lint)$"         # Safe npm commands
      - "^ls( -[lah]+)?$"               # ls with optional flags
      - "^echo "                        # Echo commands

    denied_commands:
      - "^rm -rf"                       # No rm -rf
      - "^sudo"                         # No sudo
      - "^dd if="                       # No dd
      - "chmod 777"                     # No world-writable
      - "eval"                          # No eval
```

---

## Complete Examples

### Complete Swarm Example

A multi-agent collaboration swarm where agents delegate tasks to each other:

```yaml
version: 2

swarm:
  name: "Full-Stack Development Team"
  lead: coordinator

  # Global configuration for all agents
  all_agents:
    provider: openai
    timeout: 180
    coding_agent: false
    tools: [Read, Write]

    permissions:
      Write:
        denied_paths:
          - "secrets/**"
          - "*.key"
      Bash:
        denied_commands:
          - "^rm -rf"
          - "^sudo"

    hooks:
      pre_tool_use:
        - matcher: "Write|Edit"
          type: command
          command: "scripts/validate-write.sh"
          timeout: 10

  # Swarm-level hooks
  hooks:
    swarm_start:
      - type: command
        command: "echo 'Starting development' >> log.txt"

    swarm_stop:
      - type: command
        command: "scripts/cleanup.sh"
        timeout: 30

  # Agent definitions
  agents:
    coordinator:
      description: "Lead coordinator managing the development process"
      model: gpt-5
      directory: "."
      system_prompt: |
        You are the lead coordinator. Your responsibilities:
        1. Understand requirements and create tasks
        2. Delegate to specialists (backend, frontend, reviewer)
        3. Synthesize results into final deliverable
      tools: [Read, TodoWrite]
      delegates_to: [backend, frontend, reviewer]
      coding_agent: true

      hooks:
        pre_delegation:
          - type: command
            command: "echo 'Delegating to $DELEGATION_TARGET' >> delegation.log"

    backend:
      description: "Backend developer specializing in Ruby on Rails"
      model: claude-sonnet-4
      provider: anthropic
      directory: "backend"
      system_prompt: "You build clean, testable backend APIs with Ruby on Rails"
      tools: [Read, Write, Edit, Bash, Grep, Glob]
      delegates_to: [database]
      coding_agent: true

      parameters:
        temperature: 0.3
        max_tokens: 4000

      permissions:
        Write:
          allowed_paths: ["**/*"]
          denied_paths: ["config/credentials.yml.enc"]
        Bash:
          allowed_commands:
            - "^bundle exec (rspec|rubocop)"
            - "^rails (db:migrate|routes)"

      mcp_servers:
        - name: filesystem
          type: stdio
          command: npx
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/backend"]

    frontend:
      description: "Frontend developer specializing in React and TypeScript"
      model: gpt-5
      directory: "frontend"
      system_prompt: "You build modern, accessible frontends with React and TypeScript"
      tools: [Read, Write, Edit, Bash]
      coding_agent: true

      permissions:
        Write:
          allowed_paths: ["**/*"]
        Bash:
          allowed_commands:
            - "^npm (test|run lint)"
            - "^npx (tsc|eslint)"

    database:
      description: "Database expert for schema design and migrations"
      model: gpt-5
      directory: "backend"
      system_prompt: "You design efficient database schemas and write migrations"
      tools: [Read, Write, Bash]
      coding_agent: true

      permissions:
        Write:
          allowed_paths: ["db/**/*"]
        Bash:
          allowed_commands:
            - "^rails db:(migrate|rollback|schema:dump)"

    reviewer:
      description: "Code reviewer checking for bugs and best practices"
      model: o4
      directory: "."
      system_prompt: |
        You are a thorough code reviewer. For each change:
        1. Check for bugs and edge cases
        2. Verify test coverage
        3. Suggest improvements
        4. Check security issues
      tools: [Read, Grep, Glob]
      coding_agent: false

      parameters:
        temperature: 0.2
```

---

### Complete Workflow Example

A multi-stage pipeline workflow with sequential and parallel node execution:

```yaml
version: 2

workflow:
  name: "Development Pipeline"
  start_node: planning

  # Global configuration for all agents
  all_agents:
    provider: openai
    timeout: 180
    coding_agent: true

  # Agent definitions (shared across nodes)
  agents:
    coordinator:
      description: "Lead coordinator for planning"
      model: gpt-5
      system_prompt: "You create detailed project plans"
      tools: [Read, TodoWrite]

    backend:
      description: "Backend developer specializing in Ruby on Rails"
      model: claude-sonnet-4
      provider: anthropic
      directory: "backend"
      system_prompt: "You build clean, testable backend APIs"
      tools: [Read, Write, Edit, Bash]
      delegates_to: [database]

    frontend:
      description: "Frontend developer specializing in React"
      model: gpt-5
      directory: "frontend"
      system_prompt: "You build modern, accessible frontends"
      tools: [Read, Write, Edit, Bash]

    database:
      description: "Database expert for schema design"
      model: gpt-5
      directory: "backend"
      system_prompt: "You design efficient database schemas"
      tools: [Read, Write, Bash]

    reviewer:
      description: "Code reviewer checking for bugs"
      model: o4
      system_prompt: "You review code for quality and security"
      tools: [Read, Grep, Glob]

  # Multi-stage workflow nodes
  nodes:
    planning:
      agents:
        - agent: coordinator
      output_command: "tee plan.txt"

    backend_implementation:
      agents:
        - agent: backend
          delegates_to: [database]
        - agent: database
      dependencies: [planning]
      input_command: "scripts/prepare-backend-context.sh"
      output_command: "scripts/save-backend-results.sh"

    frontend_implementation:
      agents:
        - agent: frontend
      dependencies: [planning]
      input_command: "scripts/prepare-frontend-context.sh"

    review:
      agents:
        - agent: reviewer
      dependencies: [backend_implementation, frontend_implementation]
      input_command: "scripts/gather-changes.sh"
      output_command: "scripts/format-review.sh"
```

---

## See Also

- [Ruby DSL Reference](./ruby-dsl.md): Complete Ruby DSL reference
- [CLI Reference](./cli.md): Command-line interface reference
- [Getting Started Guide](../guides/getting-started.md): Introduction to SwarmSDK
- [Quick Start CLI](../guides/quick-start-cli.md): Quick CLI examples
