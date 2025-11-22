# Getting Started with SwarmSDK

## What You'll Learn

- What SwarmSDK is and why it's valuable for complex AI tasks
- How to install and configure SwarmSDK in your Ruby project
- The fundamental concepts: agents, delegation, tools, and swarms
- How to create your first agent using YAML, Ruby DSL, and Markdown
- Essential workflows for building single and multi-agent systems
- How to interpret results and debug common issues

## Prerequisites

- **Ruby 3.2.0 or higher** installed on your system
- **Basic Ruby knowledge** - familiarity with hashes, symbols, and blocks
- **LLM API access** - an API key for OpenAI, Anthropic, or another provider
- **15-20 minutes** to complete this guide

## What is SwarmSDK?

SwarmSDK is a Ruby framework for orchestrating **teams of AI agents** that collaborate to solve complex problems. Unlike traditional single-agent systems, SwarmSDK enables you to build specialized agents that work together, each focusing on what they do best.

### Why Multi-Agent Systems?

Complex tasks often require different types of expertise. Consider a software development project:

- A **planner** agent breaks down requirements into tasks
- A **coder** agent implements features
- A **reviewer** agent checks code quality and suggests improvements
- A **tester** agent validates functionality

With SwarmSDK, each agent specializes in one area and delegates work to others when needed. This mirrors how human teams collaborate, leading to better results than a single generalist AI trying to do everything.

### Core Benefits

**Agent Specialization**: Each agent has its own system prompt, model, tools, and working directory, optimized for specific tasks.

**Flexible Delegation**: Agents can delegate work to specialists through simple function calls, creating dynamic collaboration patterns.

**Comprehensive Tooling**: Built-in tools for file operations (Read, Write, Edit), code search (Grep, Glob), command execution (Bash), and shared memory (Scratchpad).

**Fine-Grained Control**: Permissions system restricts file access, hooks customize behavior at every step, and parameters tune each agent's LLM settings.

**Multiple Interfaces**: Define swarms using declarative YAML, fluent Ruby DSL, Markdown agent files, or direct API calls—whichever fits your workflow.

## Installation

Add SwarmSDK to your Ruby project's Gemfile:

```ruby
gem 'swarm_sdk'
```

Then install:

```bash
bundle install
```

Or install directly:

```bash
gem install swarm_sdk
```

### Configure Your API Key

SwarmSDK requires an LLM provider to run. Set your API key as an environment variable:

```bash
# For OpenAI
export OPENAI_API_KEY="sk-your-key-here"

# For Anthropic Claude
export ANTHROPIC_API_KEY="sk-ant-your-key-here"
```

**Tip**: Create a `.env` file in your project root for convenience:

```bash
# .env
OPENAI_API_KEY=sk-your-key-here
```

Load it in your Ruby script:

```ruby
require 'dotenv/load'
require 'swarm_sdk'
```

### Verify Installation

Quick test to ensure everything works:

```bash
ruby -e "require 'swarm_sdk'; puts 'SwarmSDK loaded successfully!'"
```

## Core Concepts

Before writing code, let's understand SwarmSDK's architecture.

### Swarms

A **swarm** is a team of agents working together. Every swarm has:
- A **name** (for logging and debugging)
- A **lead agent** (the entry point that receives your tasks)
- One or more **agents** (the team members)

When you call `swarm.execute("task")`, the task goes to the lead agent, which can either handle it directly or delegate to other agents.

### Agents

An **agent** is an AI with specific capabilities and constraints:
- **Description**: What the agent does (required)
- **Model**: Which LLM to use (e.g., "gpt-4", "claude-sonnet-4")
- **System Prompt**: Instructions defining the agent's behavior and expertise
- **Tools**: Functions the agent can call (Read, Write, Bash, etc.)
- **Directory**: The agent's working directory for file operations
- **Delegates To**: Other agents this agent can hand off work to

### Delegation

Delegation is how agents collaborate. When an agent is configured with `delegates_to: [other_agent]`, it gains a special delegation tool.

**Delegation tool naming**: Tools are named `WorkWith{AgentName}` where AgentName is capitalized. For example:
- `delegates_to: [reviewer]` → creates `WorkWithReviewer` tool
- `delegates_to: [backend]` → creates `WorkWithBackend` tool
- `delegates_to: [qa_tester]` → creates `WorkWithQa_tester` tool

**Example flow**:
1. You send "Build a login page" to the **lead** agent
2. Lead delegates to **frontend** agent: "Create the React component"
3. Frontend delegates to **reviewer** agent: "Check this code"
4. Reviewer returns feedback to frontend
5. Frontend returns completed component to lead
6. Lead returns final result to you

Delegation creates flexible collaboration patterns without rigid workflows.

#### Delegation Isolation Modes

When multiple agents delegate to the same target, you can control whether they share the same conversation history or get isolated instances:

**Isolated Mode (Default - Recommended):**
```yaml
agents:
  tester:
    description: "Testing agent"
    # shared_across_delegations: false (default)

  frontend:
    delegates_to: [tester]  # Gets tester@frontend (isolated)

  backend:
    delegates_to: [tester]  # Gets tester@backend (separate)
```

Each delegator gets its own isolated instance with separate conversation history. This prevents context mixing and ensures clean boundaries.

**Shared Mode (Opt-in):**
```yaml
agents:
  database:
    description: "Database coordination agent"
    shared_across_delegations: true

  frontend:
    delegates_to: [database]  # Shares same database instance

  backend:
    delegates_to: [database]  # Shares same database instance
```

All delegators share the same agent instance and conversation history. Use this for stateful coordination or when context sharing is beneficial.

**Key Points:**
- **Memory is always shared**: SwarmMemory and other plugin storage is shared by base agent name across all instances
- **Only conversation history differs**: Isolated mode separates conversations, but knowledge is shared
- **Choose based on use case**: Use isolated (default) for independent tasks, shared for coordination

### Tools

Tools are functions agents call to interact with the world. SwarmSDK provides:

| Category | Tools | Purpose |
|----------|-------|---------|
| **File I/O** | Read, Write, Edit, MultiEdit | Read and modify files |
| **Search** | Grep, Glob | Find content and files |
| **Execution** | Bash | Run shell commands |
| **Web** | WebFetch | Fetch and process web content |
| **Task Management** | TodoWrite | Track progress on multi-step tasks |
| **Shared Scratchpad** | ScratchpadWrite, ScratchpadRead, ScratchpadList | Share work-in-progress between agents (volatile) |
| **Per-Agent Memory** | MemoryWrite, MemoryRead, MemoryEdit, MemoryMultiEdit, MemoryGlob, MemoryGrep, MemoryDelete | Persistent learning and knowledge storage (opt-in) |
| **Reasoning** | Think | Extended reasoning for complex problems |

**Default tools**: Every agent automatically gets **Read, Grep, and Glob** unless you explicitly disable them with `disable_default_tools: true`. Scratchpad tools (ScratchpadWrite, ScratchpadRead, ScratchpadList) are opt-in via `scratchpad: :enabled`.

**Memory tools** are opt-in for learning agents that need persistent knowledge storage.

## Configuration Formats: YAML vs Ruby DSL vs Markdown

SwarmSDK supports three equally powerful configuration formats.

### YAML Configuration

**Use YAML when**:
- You want simple, declarative configuration files
- Your hooks are shell scripts (not Ruby code)
- You prefer separating configuration from code
- You're new to SwarmSDK

**Example**:
```yaml
version: 2
swarm:
  name: "My First Swarm"
  lead: assistant
  agents:
    assistant:
      description: "A helpful assistant"
      model: "gpt-4"
      system_prompt: "You are a helpful assistant."
      tools:
        - Write
```

### Ruby DSL

**Use Ruby DSL when**:
- You need dynamic configuration (variables, conditionals, loops)
- You want to write hooks as Ruby blocks (inline logic)
- You prefer IDE autocomplete and type checking
- You're building reusable agent libraries

**Example - Inline Definition**:
```ruby
swarm = SwarmSDK.build do
  name "My First Swarm"
  lead :assistant

  agent :assistant do
    description "A helpful assistant"
    model "gpt-4"
    system_prompt "You are a helpful assistant."
    tools :Write
  end
end
```

**Example - Load from Markdown File**:
```ruby
swarm = SwarmSDK.build do
  name "My First Swarm"
  lead :assistant

  # Load agent from markdown file content
  # Name is always required (overrides any name in frontmatter)
  agent :assistant, File.read("agents/assistant.md")
end
```

**Example - Mix Inline and Markdown**:
```ruby
swarm = SwarmSDK.build do
  name "Dev Team"
  lead :frontend

  # Inline DSL agent
  agent :frontend do
    description "Frontend developer"
    model "gpt-4"
    system_prompt "You build UIs"
  end

  # Load backend from markdown file
  agent :backend, File.read("agents/backend.md")
end
```

**Note**: Use `system_prompt` in the Ruby DSL to set the agent's instructions.

### Markdown Agent Files

**Use Markdown when**:
- You want to define agents in separate, readable files
- You prefer writing prompts in a documentation format
- You want to version control agent definitions independently
- You're sharing agent configurations with non-developers

**Example**: Create `agents/assistant.md`:

```markdown
---
description: "A helpful assistant"
model: "gpt-4"
tools:
  - Write
  - Edit
delegates_to:
  - reviewer
---

# Assistant Agent

You are a helpful assistant who writes clear, maintainable code.

## Your Responsibilities

- Write clean, well-documented code
- Follow best practices and style guides
- Delegate code reviews to the reviewer agent

## Best Practices

- Always add comments for complex logic
- Use descriptive variable names
- Test your code before finalizing
```

Then reference it in your YAML configuration:

```yaml
# swarm.yml
version: 2
swarm:
  name: "My Swarm"
  lead: assistant
  agents:
    assistant: "agents/assistant.md"
```

**Note**: When the agent value is a string, it's treated as a file path. You can also use the hash format if you need to override settings from the markdown file:

```yaml
agents:
  assistant:
    agent_file: "agents/assistant.md"
    timeout: 120  # Override timeout from file
```

```ruby
require 'swarm_sdk'

# Load swarm from YAML (which references the Markdown file)
swarm = SwarmSDK.load_file('swarm.yml')
result = swarm.execute("Your task here")
```

**Note**: Markdown agent definitions can be used in multiple ways:
- **YAML**: Reference file path: `assistant: "agents/assistant.md"`
- **Ruby DSL**: Pass file content: `agent :assistant, File.read("agents/assistant.md")`
- **Ruby DSL**: Or inline markdown: `agent :assistant, <<~MD ... MD`

In the Ruby DSL, the agent name is **always required** and will override any `name` field in the markdown frontmatter.

**All three approaches are powerful**—choose what fits your workflow:
- **YAML**: Best for simple, declarative configs with file references
- **Ruby DSL**: Best for dynamic configs, inline hooks, and programmatic agent definitions
- **Markdown**: Best for reusable agent definitions that can be version controlled independently

The rest of this guide shows examples in all three formats.

## Your First Agent

Let's create the simplest possible agent: one that answers questions.

### Understanding What We're Building

We'll create:
1. A swarm named "My First Swarm"
2. One agent called "assistant"
3. The agent will use GPT-4 and have basic file reading capability

### YAML Approach

Create a file called `swarm.yml`:

```yaml
version: 2
swarm:
  name: "My First Swarm"
  lead: assistant

  agents:
    assistant:
      description: "A helpful assistant"
      model: "gpt-4"
      system_prompt: |
        You are a helpful assistant.
        Answer questions clearly and concisely.
      tools:
        - Write
```

Create a file called `run.rb`:

```ruby
require 'swarm_sdk'

# Load swarm from YAML
swarm = SwarmSDK.load_file('swarm.yml')

# Execute a task
result = swarm.execute("What is 2 + 2?")

puts "Response: #{result.content}"
puts "Success: #{result.success?}"
puts "Duration: #{result.duration}s"
```

### Ruby DSL Approach

Create a file called `run.rb`:

```ruby
require 'swarm_sdk'

# Build swarm with DSL
swarm = SwarmSDK.build do
  name "My First Swarm"
  lead :assistant

  agent :assistant do
    description "A helpful assistant"
    model "gpt-4"
    system_prompt "You are a helpful assistant. Answer questions clearly and concisely."
    tools :Write
  end
end

# Execute a task
result = swarm.execute("What is 2 + 2?")

puts "Response: #{result.content}"
puts "Success: #{result.success?}"
puts "Duration: #{result.duration}s"
```

### Markdown Approach

Create `agents/assistant.md`:

```markdown
---
description: "A helpful assistant"
model: "gpt-4"
tools:
  - Write
---

# Helpful Assistant

You are a helpful assistant.

Answer questions clearly and concisely.
```

Create `swarm.yml`:

```yaml
version: 2
swarm:
  name: "My First Swarm"
  lead: assistant
  agents:
    assistant: "agents/assistant.md"
```

Create `run.rb`:

```ruby
require 'swarm_sdk'

# Load swarm from YAML (which references the Markdown file)
swarm = SwarmSDK.load_file('swarm.yml')

# Execute a task
result = swarm.execute("What is 2 + 2?")

puts "Response: #{result.content}"
puts "Success: #{result.success?}"
puts "Duration: #{result.duration}s"
```

### Run Your Agent

```bash
ruby run.rb
```

**Expected output**:
```
Response: The answer is 4.
Success: true
Duration: 1.23s
```

### What's Happening?

Let's break down each part:

1. **`version: 2`** (YAML only): Specifies SwarmSDK configuration version
2. **`name "My First Swarm"`**: Names your swarm (useful for logging)
3. **`lead :assistant`**: Designates which agent receives your tasks
4. **`agent :assistant do`**: Defines an agent with a unique name
5. **`description`**: Explains the agent's role (required field)
6. **`model "gpt-4"`**: Specifies which LLM to use
7. **`system_prompt`**: Instructions that guide the agent's behavior
8. **`tools :Write`**: Grants the agent Write capability (Read is already included by default)
9. **`swarm.execute("...")`**: Sends a task to the lead agent and returns the result

## Understanding Results

The `execute` method returns a `Result` object with detailed information:

```ruby
result = swarm.execute("What is 2 + 2?")

# Access response content
result.content      # => "The answer is 4."

# Check success status
result.success?     # => true

# Get performance metrics
result.duration     # => 1.23 (seconds)
result.total_cost   # => 0.0015 (USD)
result.total_tokens # => 450

# Get involved agents (useful in multi-agent swarms)
result.agents_involved  # => [:assistant]

# Check for errors
result.error        # => nil (or exception object if failed)
```

### Result Object Reference

| Property | Type | Description |
|----------|------|-------------|
| `content` | String | The final response from the lead agent |
| `success?` | Boolean | Whether execution completed without errors |
| `duration` | Float | Total execution time in seconds |
| `total_cost` | Float | Total cost in USD (if provider reports it) |
| `total_tokens` | Integer | Total tokens used across all agents |
| `agents_involved` | Array[Symbol] | List of agents that participated |
| `error` | Exception \| nil | Error object if execution failed |

### Common Result Patterns

```ruby
# Check if successful before using result
if result.success?
  puts result.content
else
  puts "Error: #{result.error.message}"
end

# Log cost and performance
puts "Cost: $#{result.total_cost.round(4)}"
puts "Time: #{result.duration.round(2)}s"
puts "Tokens: #{result.total_tokens}"

# Check which agents were involved
puts "Agents used: #{result.agents_involved.join(', ')}"

# Handle errors gracefully
begin
  result = swarm.execute("Complex task")

  # Check result success instead of catching exceptions
  unless result.success?
    puts "Execution failed: #{result.error.message}"
  end
rescue SwarmSDK::ConfigurationError => e
  puts "Configuration error: #{e.message}"
end
```

## Common Workflows

Now that you understand the basics, let's explore common patterns.

### Single Agent with File Operations

**Use case**: An agent that reads a file and summarizes it.

**YAML** (`file-reader.yml`):
```yaml
version: 2
swarm:
  name: "File Reader"
  lead: reader

  agents:
    reader:
      description: "Reads and summarizes files"
      model: "gpt-4"
      system_prompt: |
        You are a file analysis expert.
        Read files and provide concise, insightful summaries.
      # Read is included by default - no tools needed!
      directory: "."
```

**Ruby DSL**:
```ruby
swarm = SwarmSDK.build do
  name "File Reader"
  lead :reader

  agent :reader do
    description "Reads and summarizes files"
    model "gpt-4"
    system_prompt "You are a file analysis expert. Read files and provide concise, insightful summaries."
    directory "."
  end
end

# Use it
result = swarm.execute("Read README.md and summarize its key points")
```

**Markdown** (`agents/reader.md`):
```markdown
---
description: "Reads and summarizes files"
model: "gpt-4"
directory: "."
---

# File Analysis Expert

You are a file analysis expert.

Read files and provide concise, insightful summaries.
```

**Why this works**: The agent has Read tool by default and can access files in the specified directory.

### Multi-Agent Collaboration

**Use case**: A code review system with a coder and reviewer.

**YAML** (`code-review.yml`):
```yaml
version: 2
swarm:
  name: "Code Review Team"
  lead: coder

  agents:
    coder:
      description: "Writes clean, maintainable code"
      model: "gpt-4"
      system_prompt: |
        You are an expert programmer.
        Write code and delegate to the reviewer for feedback.
      tools:
        - Write
        - Edit
      delegates_to:
        - reviewer

    reviewer:
      description: "Reviews code for quality and issues"
      model: "claude-sonnet-4"
      system_prompt: |
        You are a code review expert.
        Analyze code for bugs, style issues, and improvements.
      # Only needs Read (included by default)
```

**Ruby DSL**:
```ruby
swarm = SwarmSDK.build do
  name "Code Review Team"
  lead :coder

  agent :coder do
    description "Writes clean, maintainable code"
    model "gpt-4"
    system_prompt "You are an expert programmer. Write code and delegate to the reviewer for feedback."
    tools :Write, :Edit
    delegates_to :reviewer
  end

  agent :reviewer do
    description "Reviews code for quality and issues"
    model "claude-sonnet-4"
    system_prompt "You are a code review expert. Analyze code for bugs, style issues, and improvements."
  end
end

# Use it
result = swarm.execute("Write a function to validate email addresses and get it reviewed")
```

**Markdown** (`agents/coder.md` + `agents/reviewer.md` + `swarm.yml`):

`agents/coder.md`:
```markdown
---
description: "Writes clean, maintainable code"
model: "gpt-4"
tools:
  - Write
  - Edit
delegates_to:
  - reviewer
---

# Expert Programmer

You are an expert programmer.

Write code and delegate to the reviewer for feedback.
```

`agents/reviewer.md`:
```markdown
---
description: "Reviews code for quality and issues"
model: "claude-sonnet-4"
---

# Code Review Expert

You are a code review expert.

Analyze code for bugs, style issues, and improvements.
```

`swarm.yml`:
```yaml
version: 2
swarm:
  name: "Code Review Team"
  lead: coder
  agents:
    coder: "agents/coder.md"
    reviewer: "agents/reviewer.md"
```

Then load and use:
```ruby
swarm = SwarmSDK.load_file('swarm.yml')
result = swarm.execute("Write a function to validate email addresses and get it reviewed")
```

**How delegation works**: The coder writes code, then calls the `WorkWithReviewer` tool to get feedback. The reviewer analyzes and returns suggestions. The coder can iterate based on feedback.

### Using Multiple Tools

**Use case**: An agent that searches, reads, and modifies files.

**YAML** (`refactor-assistant.yml`):
```yaml
version: 2
swarm:
  name: "Refactor Assistant"
  lead: refactorer

  agents:
    refactorer:
      description: "Finds and refactors code patterns"
      model: "gpt-4"
      system_prompt: |
        You are a refactoring expert.
        Use Grep to find code patterns, Read to understand context,
        and Edit to make improvements.
      tools:
        - Edit
        - Bash
      # Grep and Read included by default
      directory: "./src"
```

**Ruby DSL**:
```ruby
swarm = SwarmSDK.build do
  name "Refactor Assistant"
  lead :refactorer

  agent :refactorer do
    description "Finds and refactors code patterns"
    model "gpt-4"
    system_prompt "You are a refactoring expert. Use Grep to find code patterns, Read to understand context, and Edit to make improvements."
    tools :Edit, :Bash
    directory "./src"
  end
end

# Use it
result = swarm.execute("Find all functions longer than 50 lines and suggest refactorings")
```

**Tool workflow**:
1. Agent uses Grep to find long functions: `Grep(pattern: "def .*", path: ".")`
2. Agent uses Read to examine each file: `Read(file_path: "file.rb")`
3. Agent uses Edit to refactor: `Edit(file_path: "file.rb", old_string: "...", new_string: "...")`

### Customizing Agent Behavior

**Use case**: Different agents need different LLM parameters.

**YAML** (`customized-agents.yml`):
```yaml
version: 2
swarm:
  name: "Customized Team"
  lead: creative

  agents:
    creative:
      description: "Creative brainstormer"
      model: "gpt-4"
      system_prompt: "Generate creative ideas."
      parameters:
        temperature: 1.5  # More creative/random
        top_p: 0.95

    analytical:
      description: "Analytical reviewer"
      model: "claude-sonnet-4"
      system_prompt: "Analyze ideas critically."
      parameters:
        temperature: 0.3  # More focused/deterministic
```

**Ruby DSL**:
```ruby
swarm = SwarmSDK.build do
  name "Customized Team"
  lead :creative

  agent :creative do
    description "Creative brainstormer"
    model "gpt-4"
    system_prompt "Generate creative ideas."
    parameters temperature: 1.5, top_p: 0.95
  end

  agent :analytical do
    description "Analytical reviewer"
    model "claude-sonnet-4"
    system_prompt "Analyze ideas critically."
    parameters temperature: 0.3
  end
end
```

**Why customize parameters**:
- **Temperature**: Controls randomness (0.0-2.0). Higher = more creative, lower = more focused.
- **Top P**: Controls diversity (0.0-1.0). Higher = more diverse outputs.
- **Max tokens**: Limits response length.

### Using Scratchpad for Agent Communication

**Use case**: Agents sharing data without explicit delegation.

**YAML** (`research-team.yml`):
```yaml
version: 2
swarm:
  name: "Research Team"
  lead: coordinator

  agents:
    coordinator:
      description: "Coordinates research tasks"
      model: "gpt-4"
      system_prompt: |
        Coordinate research. Use ScratchpadWrite to share findings.
      delegates_to:
        - researcher
        - analyst

    researcher:
      description: "Gathers raw data"
      model: "gpt-4"
      system_prompt: |
        Research topics and write findings to scratchpad using file path "research/data".

    analyst:
      description: "Analyzes research data"
      model: "claude-sonnet-4"
      system_prompt: |
        Read "research/data" from scratchpad and provide analysis.
```

**Ruby DSL**:
```ruby
swarm = SwarmSDK.build do
  name "Research Team"
  lead :coordinator

  agent :coordinator do
    description "Coordinates research tasks"
    model "gpt-4"
    system_prompt "Coordinate research. Use ScratchpadWrite to share findings."
    delegates_to :researcher, :analyst
  end

  agent :researcher do
    description "Gathers raw data"
    model "gpt-4"
    system_prompt 'Research topics and write findings to scratchpad using file path "research/data".'
  end

  agent :analyst do
    description "Analyzes research data"
    model "claude-sonnet-4"
    system_prompt 'Read "research/data" from scratchpad and provide analysis.'
  end
end

# Use it
result = swarm.execute("Research Ruby performance optimization techniques and analyze them")
```

**How it works**:
1. Coordinator delegates to researcher: "Gather data on Ruby performance"
2. Researcher uses `ScratchpadWrite(file_path: "research/data", content: "...", title: "Research Data")`
3. Coordinator delegates to analyst: "Analyze the research"
4. Analyst uses `ScratchpadRead(file_path: "research/data")` to get the data
5. Analyst provides analysis

## Common Pitfalls and Solutions

### Pitfall 1: Missing Lead Agent

**Error**:
```ruby
# ❌ No lead agent specified
swarm = SwarmSDK.build do
  name "My Swarm"
  agent :assistant do
    description "Helper"
    model "gpt-4"
  end
end
# => ConfigurationError: No lead agent set
```

**Solution**:
```ruby
# ✅ Always specify lead
swarm = SwarmSDK.build do
  name "My Swarm"
  lead :assistant  # Don't forget this!
  agent :assistant do
    description "Helper"
    model "gpt-4"
  end
end
```

### Pitfall 2: Missing Required Description

**Error**:
```ruby
# ❌ Description required
agent :assistant do
  model "gpt-4"
  system_prompt "You are helpful."
end
# => ConfigurationError: missing required 'description'
```

**Solution**:
```ruby
# ✅ Always include description
agent :assistant do
  description "A helpful assistant"  # Required!
  model "gpt-4"
  system_prompt "You are helpful."
end
```

### Pitfall 3: Invalid Model Names

**Error**:
```ruby
# ❌ Model doesn't exist
agent :assistant do
  description "Helper"
  model "gpt-99"  # Typo or non-existent model
end
# => May fail at runtime when trying to call LLM
```

**Solution**:
```ruby
# ✅ Use valid model identifiers
agent :assistant do
  description "Helper"
  model "gpt-4"  # Valid: gpt-4, gpt-4-turbo, claude-sonnet-4, etc.
end
```

**Valid model examples**:
- OpenAI: `"gpt-4"`, `"gpt-4-turbo"`, `"gpt-3.5-turbo"`
- Anthropic: `"claude-sonnet-4"`, `"claude-opus-4"`, `"claude-haiku-4"`
- Others: Depends on your provider configuration

### Pitfall 4: Delegation Without Configuration

**Error**:
```ruby
# ❌ Trying to delegate to unconfigured agent
swarm = SwarmSDK.build do
  name "Team"
  lead :leader

  agent :leader do
    description "Leader"
    model "gpt-4"
    # Missing: delegates_to :helper
  end

  agent :helper do
    description "Helper"
    model "gpt-4"
  end
end
# Leader won't have WorkWithHelper tool!
```

**Solution**:
```ruby
# ✅ Configure delegation explicitly
agent :leader do
  description "Leader"
  model "gpt-4"
  delegates_to :helper  # Now leader can delegate!
end
```

### Pitfall 5: Tool Not Available

**Error**:
```ruby
# Agent tries to use Write but doesn't have it
agent :reader do
  description "Reader"
  model "gpt-4"
  disable_default_tools true  # Disables all default tools
  tools :Read  # Only Read available
end
# If agent tries to write: ToolNotFoundError
```

**Solution**:
```ruby
# ✅ Add tools you need
agent :reader do
  description "Reader"
  model "gpt-4"
  tools :Read, :Write  # Explicitly add Write
end
```

### Pitfall 6: Incorrect Gem Name

**Error**:
```ruby
# ❌ Wrong gem name
gem 'swarm-sdk'  # Wrong!
gem 'swarmcore'  # Wrong!

# ❌ Wrong require
require 'swarm-sdk'  # Wrong!
```

**Solution**:
```ruby
# ✅ Correct gem name and require
# In Gemfile:
gem 'swarm_sdk'

# In Ruby code:
require 'swarm_sdk'

# Installation:
# gem install swarm_sdk
```

### Pitfall 7: Wrong Ruby Version

**Error**:
```bash
# Using Ruby 3.1 or earlier
ruby -v
# => ruby 3.1.0

gem install swarm_sdk
# => ERROR: swarm_sdk requires Ruby >= 3.2.0
```

**Solution**:
```bash
# ✅ Use Ruby 3.2.0 or higher
# Check version
ruby -v
# => ruby 3.2.0 (or higher)

# Install/upgrade Ruby if needed:
rbenv install 3.2.0
rbenv global 3.2.0
# or
rvm install 3.2.0
rvm use 3.2.0
```

## Testing Your Setup

Here's a comprehensive test script to verify SwarmSDK is working:

```ruby
require 'swarm_sdk'

puts "Testing SwarmSDK installation..."
puts "Ruby version: #{RUBY_VERSION}"
puts ""

begin
  # Test 1: Basic swarm creation
  puts "Test 1: Creating swarm..."
  swarm = SwarmSDK.build do
    name "Setup Test"
    lead :test_agent

    agent :test_agent do
      description "Test agent"
      model "gpt-4"
      system_prompt "Reply with exactly: 'SwarmSDK is working!'"
    end
  end
  puts "✅ Swarm created successfully"
  puts ""

  # Test 2: Simple execution
  puts "Test 2: Executing task..."
  result = swarm.execute("Test")

  if result.success?
    puts "✅ Execution successful"
    puts "   Response: #{result.content}"
    puts "   Duration: #{result.duration.round(2)}s"
    puts "   Cost: $#{result.total_cost.round(4)}"
    puts "   Agents: #{result.agents_involved.inspect}"
  else
    puts "❌ Execution failed: #{result.error.message}"
    puts "   Check your API key and network connection"
  end
  puts ""

  # Test 3: Multi-agent delegation
  puts "Test 3: Testing delegation..."
  swarm2 = SwarmSDK.build do
    name "Delegation Test"
    lead :primary

    agent :primary do
      description "Primary agent"
      model "gpt-4"
      system_prompt "Delegate to helper with message: 'Hello!'"
      delegates_to :helper
    end

    agent :helper do
      description "Helper agent"
      model "gpt-4"
      system_prompt "Reply with: 'Delegation works!'"
    end
  end

  result2 = swarm2.execute("Test delegation")
  if result2.success? && result2.agents_involved.length > 1
    puts "✅ Delegation works"
    puts "   Agents involved: #{result2.agents_involved.inspect}"
  else
    puts "❌ Delegation failed"
  end

rescue StandardError => e
  puts "❌ Error: #{e.class.name}"
  puts "   Message: #{e.message}"
  puts "   Backtrace: #{e.backtrace.first(3).join("\n   ")}"
  puts ""
  puts "Common fixes:"
  puts "  - Verify API key is set: echo $OPENAI_API_KEY"
  puts "  - Check network connection"
  puts "  - Ensure Ruby >= 3.2.0"
end
```

**Expected output**:
```
Testing SwarmSDK installation...
Ruby version: 3.2.0

Test 1: Creating swarm...
✅ Swarm created successfully

Test 2: Executing task...
✅ Execution successful
   Response: SwarmSDK is working!
   Duration: 1.23s
   Cost: $0.0015
   Agents: [:test_agent]

Test 3: Testing delegation...
✅ Delegation works
   Agents involved: [:primary, :helper]
```

## Next Steps

Congratulations! You've learned the fundamentals of SwarmSDK.

### Continue Learning

**Core Tutorials** (in recommended order):
1. **[Complete Tutorial](complete-tutorial.md)** - Comprehensive guide building a real application
2. **[Quick Start CLI](quick-start-cli.md)** - Using SwarmSDK from the command line
3. **[Rails Integration](rails-integration.md)** - Integrating SwarmSDK with Rails applications

**Advanced Topics**:
- **[Permissions Guide](permissions.md)** - Control file and command access securely
- **[Hooks Complete Guide](hooks-complete-guide.md)** - Customize behavior at every step
- **[Scratchpad Guide](how-to-use-scratchpad.md)** - Share data between agents
- **[Performance Tuning](performance-tuning.md)** - Optimize for speed and cost

### Key Concepts to Explore

**Agent Delegation Patterns**: Learn advanced collaboration strategies like hierarchical delegation, peer collaboration, and specialist chains.

**Reusable Agent Definitions**: Use the Global Agent Registry (`SwarmSDK.agent`) to define agents once and reuse them across multiple swarms—perfect for large projects with shared agents.

**Permissions System**: Discover how to restrict agents to specific directories, prevent dangerous commands, and create secure multi-agent systems.

**Hooks and Customization**: Master pre/post hooks for tool calls, prompt injection, and workflow automation.

**MCP Server Integration**: Connect to external tools and services using the Model Context Protocol.

**Node-Based Workflows**: Build multi-stage pipelines where different agent teams handle each stage.

### Real-World Examples

Check out complete working examples in the `examples/` directory:

- **Code Review Bot** - Multi-agent code review system
- **Documentation Generator** - Automated documentation from code
- **Test Suite Builder** - Generate comprehensive test suites
- **Refactoring Assistant** - Find and fix code smells

## Where to Get Help

- **Documentation**: [SwarmSDK Guides](../README.md)
- **API Reference**: [API Documentation](../../api/)
- **Examples**: [Example Swarms](../../../examples/v2/)
- **Issues**: [GitHub Issues](https://github.com/parruda/claude-swarm/issues)

## Summary

You've learned:

✅ **What SwarmSDK is** - A framework for building collaborative AI agent teams

✅ **Installation** - How to add SwarmSDK to your project and configure API keys

✅ **Core concepts** - Swarms, agents, delegation, and tools

✅ **Configuration formats** - YAML, Ruby DSL, and Markdown approaches

✅ **Creating agents** - How to define agents with models, prompts, and tools

✅ **Understanding results** - How to interpret execution results and metrics

✅ **Common workflows** - Single agent, multi-agent, and tool usage patterns

✅ **Avoiding pitfalls** - Common mistakes and how to fix them

✅ **Testing setup** - How to verify everything works correctly

**Next**: [Complete Tutorial →](complete-tutorial.md)

---

## Quick Reference Card

### Minimal Working Swarm (Ruby DSL)

```ruby
require 'swarm_sdk'

swarm = SwarmSDK.build do
  name "My Swarm"
  lead :agent_name

  agent :agent_name do
    description "What it does"
    model "gpt-4"
    system_prompt "Instructions"
    tools :Write, :Edit
  end
end

result = swarm.execute("Your task here")
puts result.content if result.success?
```

### Minimal Working Swarm (YAML)

```yaml
# swarm.yml
version: 2
swarm:
  name: "My Swarm"
  lead: agent_name
  agents:
    agent_name:
      description: "What it does"
      model: "gpt-4"
      system_prompt: "Instructions"
      tools:
        - Write
        - Edit
```

```ruby
# run.rb
require 'swarm_sdk'
swarm = SwarmSDK.load_file('swarm.yml')
result = swarm.execute("Your task here")
puts result.content if result.success?
```

### Minimal Working Agent (Markdown)

```markdown
<!-- agents/agent_name.md -->
---
description: "What it does"
model: "gpt-4"
tools:
  - Write
  - Edit
---

# Agent Name

Instructions for the agent.
```

```yaml
# swarm.yml
version: 2
swarm:
  name: "My Swarm"
  lead: agent_name
  agents:
    agent_name: "agents/agent_name.md"
```

```ruby
# run.rb
require 'swarm_sdk'
swarm = SwarmSDK.load_file('swarm.yml')
result = swarm.execute("Your task here")
```

### Essential Fields

**Required**:
- `name` - Swarm name (for logging)
- `lead` - Entry point agent (symbol)
- `description` - Agent's role (required for each agent)

**Common**:
- `model` - LLM to use (e.g., "gpt-4", "claude-sonnet-4")
- `system_prompt` - Agent instructions
- `tools` - Additional tools (Write, Edit, Bash, etc.)
- `delegates_to` - Agents this agent can delegate to
- `directory` - Working directory for file operations

### Default Tools (Always Available)

Unless `disable_default_tools: true`:
- **Read** - Read files
- **Grep** - Search file contents
- **Glob** - Find files by pattern
- **TodoWrite** - Track tasks
- **Think** - Extended reasoning
- **WebFetch** - Fetch and process web content
- **ScratchpadWrite, ScratchpadRead, ScratchpadList** - Shared scratchpad (volatile)

### Common Tools (Add Explicitly)

```ruby
tools :Write        # Create/overwrite files
tools :Edit         # Modify existing files
tools :MultiEdit    # Batch file edits
tools :Bash         # Run shell commands
```

### Delegation Pattern

```ruby
agent :leader do
  description "Coordinates work"
  model "gpt-4"
  delegates_to :worker  # Creates WorkWithWorker tool
end

agent :worker do
  description "Does the work"
  model "gpt-4"
end
```

### Result Object Methods

```ruby
result = swarm.execute("task")

result.content         # Response text
result.success?        # Boolean
result.duration        # Float (seconds)
result.total_cost      # Float (USD)
result.total_tokens    # Integer
result.agents_involved # Array[Symbol]
result.error           # Exception | nil
```

### Model Examples

**OpenAI**:
- `"gpt-4"` - Most capable
- `"gpt-4-turbo"` - Faster, cheaper
- `"gpt-3.5-turbo"` - Fast, economical

**Anthropic**:
- `"claude-opus-4"` - Most capable
- `"claude-sonnet-4"` - Balanced
- `"claude-haiku-4"` - Fast, economical

### Parameters for Tuning

```ruby
parameters temperature: 0.7    # 0.0 (focused) to 2.0 (creative)
parameters top_p: 0.9          # 0.0 to 1.0 (diversity)
parameters max_tokens: 2000    # Response length limit
```

### Common Patterns

**Single agent**:
```ruby
swarm = SwarmSDK.build do
  name "Solo"
  lead :worker
  agent :worker do
    description "Does everything"
    model "gpt-4"
  end
end
```

**Delegation chain**:
```ruby
swarm = SwarmSDK.build do
  name "Chain"
  lead :first
  agent :first { description "First"; model "gpt-4"; delegates_to :second }
  agent :second { description "Second"; model "gpt-4"; delegates_to :third }
  agent :third { description "Third"; model "gpt-4" }
end
```

**Parallel team**:
```ruby
swarm = SwarmSDK.build do
  name "Team"
  lead :coordinator
  agent :coordinator do
    description "Coordinates"
    model "gpt-4"
    delegates_to :frontend, :backend, :testing
  end
  agent :frontend { description "Frontend"; model "gpt-4" }
  agent :backend { description "Backend"; model "gpt-4" }
  agent :testing { description "Testing"; model "gpt-4" }
end
```
