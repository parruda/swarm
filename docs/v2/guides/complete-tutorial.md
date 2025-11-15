# SwarmSDK Complete Tutorial

**A comprehensive, in-depth guide covering every SwarmSDK feature**

## Table of Contents

- [Part 1: Fundamentals](#part-1-fundamentals)
- [Part 2: Tools and Permissions](#part-2-tools-and-permissions)
- [Part 3: Agent Collaboration](#part-3-agent-collaboration)
- [Part 4: Hooks System](#part-4-hooks-system)
- [Part 5: Node Workflows](#part-5-node-workflows)
- [Part 6: Advanced Configuration](#part-6-advanced-configuration)
- [Part 7: Production Features](#part-7-production-features)
- [Part 8: Best Practices](#part-8-best-practices)

---

## Part 1: Fundamentals

### 1.1 Agent Configuration Basics

Every agent needs three essential fields:

```ruby
agent :backend do
  description "Backend developer"  # Required: What the agent does
  model "gpt-4"                    # Which LLM to use
  system_prompt "You build APIs"   # Instructions for the agent
end
```

**YAML equivalent**:
```yaml
backend:
  description: "Backend developer"
  model: "gpt-4"
  system_prompt: "You build APIs"
```

### 1.2 Models and Providers

**OpenAI models**:
```ruby
agent :gpt_agent do
  description "GPT agent"
  model "gpt-4"              # GPT-4
  # Also: "gpt-4-turbo", "gpt-3.5-turbo", "gpt-4o"
  provider "openai"          # Default provider
end
```

**Anthropic models**:
```yaml
claude_agent:
  description: "Claude agent"
  model: "claude-sonnet-4"
  provider: "anthropic"
  # Also: "claude-opus-4", "claude-haiku-4"
```

**Using custom providers**:
```ruby
agent :custom_agent do
  description "Custom provider agent"
  model "my-custom-model"
  provider "custom"          # Any custom provider
  base_url "https://api.example.com/v1"  # Custom endpoint
end
```

**Why different providers?** Different models have different strengths:
- GPT-4: Strong reasoning, code generation
- Claude Sonnet: Fast, cost-effective, great at following instructions
- Claude Opus: Best reasoning and analysis
- Claude Haiku: Fastest, cheapest for simple tasks

### 1.3 Working Directories

Each agent operates in a specific directory:

```ruby
agent :frontend do
  description "Frontend developer"
  model "gpt-4"
  system_prompt "You work on React components"
  directory "./frontend"      # Agent's working directory
  tools :Write, :Edit
end
```

**Why directories matter**:
- File tools (Read, Write, Edit) operate relative to the agent's directory
- Permissions are enforced within this scope
- Multiple agents can work in different directories simultaneously

**YAML example**:
```yaml
frontend:
  description: "Frontend developer"
  model: "gpt-4"
  system_prompt: "You work on React components"
  directory: "./frontend"
  tools:
    - Write
    - Edit
```

### 1.4 System Prompts

System prompts define agent behavior and expertise:

**Simple prompt**:
```ruby
agent :helper do
  description "Helpful assistant"
  model "gpt-4"
  system_prompt "You are a helpful assistant. Answer questions clearly."
end
```

**Detailed prompt with examples**:
```yaml
code_reviewer:
  description: "Code reviewer"
  model: "claude-sonnet-4"
  system_prompt: |
    You are an expert code reviewer.

    Your responsibilities:
    - Check for bugs and edge cases
    - Verify error handling
    - Suggest performance improvements
    - Ensure code follows best practices

    When reviewing:
    1. Start with overall assessment
    2. List specific issues with line numbers
    3. Suggest concrete improvements
    4. Highlight what was done well

    Format your reviews as:
    ## Summary
    [Overall assessment]

    ## Issues Found
    - [Issue with line number]

    ## Suggestions
    - [Specific improvements]

    ## Positive Feedback
    - [What was done well]
```

**When to use detailed prompts**: For complex, specialized tasks where specific behavior is needed.

### 1.5 Coding Agent Flag

The `coding_agent` flag includes SwarmSDK's base system prompt for coding tasks:

```ruby
agent :coder do
  description "Programmer"
  model "gpt-4"
  coding_agent true           # Include base coding prompt
  system_prompt "You write clean Ruby code"
end
```

**What the base prompt includes**:
- File operation best practices
- TodoWrite tool usage instructions
- Scratchpad tool documentation
- General coding guidelines

**When to use**:
- `coding_agent: true` - For agents that write/modify code
- `coding_agent: false` (default) - For agents that don't code (analysts, reviewers, planners)

### 1.6 Running Swarms

**CLI (Interactive)**:
```bash
swarm run config.yml
```

**CLI (Non-interactive)**:
```bash
swarm run config.yml -p "Build a REST API"
```

**SDK (Ruby)**:
```ruby
swarm = SwarmSDK.build do
  name "Dev Team"
  lead :coder
  agent :coder do
    description "Programmer"
    model "gpt-4"
    system_prompt "You write code"
    tools :Write, :Edit
  end
end

result = swarm.execute("Build a REST API")
puts result.content
puts "Cost: $#{result.total_cost}"
puts "Duration: #{result.duration}s"
```

**When to use each**:
- CLI interactive: Exploratory work, conversations
- CLI non-interactive: Automation, scripting
- SDK: Custom applications, complex workflows

---

## Part 2: Tools and Permissions

### 2.1 Built-In Tools

SwarmSDK provides comprehensive tools for file operations, search, and execution.

#### Read Tool

Read files from the filesystem:

```ruby
agent :reader do
  description "File reader"
  model "gpt-4"
  system_prompt "Read and analyze files"
  directory "/projects/app"
  # Read included by default
end
```

**Usage by agent**:
```
Read(file_path: "src/main.rb")
Read(file_path: "config/database.yml")
```

**Features**:
- Reads files relative to agent's directory
- Supports line ranges (offset, limit)
- Handles large files efficiently

#### Write Tool

Create new files:

```yaml
writer:
  description: "File writer"
  model: "gpt-4"
  system_prompt: "Create new files"
  directory: "./output"
  tools:
    - Write
```

**Usage**:
```
Write(file_path: "result.txt", content: "...")
Write(file_path: "src/new_module.rb", content: "class NewModule\n...")
```

**Security**: Write is restricted to agent's directory by default (configurable with permissions).

#### Edit Tool

Modify existing files with string replacement:

```ruby
agent :editor do
  description "Code editor"
  model "gpt-4"
  system_prompt "Modify existing files"
  tools :Edit
end
```

**Usage**:
```
Edit(file_path: "main.rb", old_string: "def old_method", new_string: "def new_method")
```

**Why Edit over Write**: Precise changes without rewriting entire files.

#### MultiEdit Tool

Apply multiple edits to a file in one operation:

```ruby
agent :refactorer do
  description "Code refactorer"
  model "gpt-4"
  system_prompt "Refactor code efficiently"
  tools :MultiEdit
end
```

**Usage**:
```
MultiEdit(
  file_path: "main.rb",
  edits: [
    {old_string: "old1", new_string: "new1"},
    {old_string: "old2", new_string: "new2"}
  ]
)
```

**When to use**: When making many changes to one file.

#### Bash Tool

Execute shell commands:

```yaml
executor:
  description: "Command executor"
  model: "gpt-4"
  system_prompt: "Run commands and analyze output"
  tools:
    - Bash
```

**Usage**:
```
Bash(command: "ls -la")
Bash(command: "git status")
Bash(command: "npm test")
```

**Security considerations**: Can run any command, so use with permissions.

#### Grep Tool

Search file contents with regex:

```ruby
agent :searcher do
  description "Code searcher"
  model "gpt-4"
  system_prompt "Find code patterns"
  # Grep included by default
end
```

**Usage**:
```
Grep(pattern: "def .*authenticate", path: ".")
Grep(pattern: "TODO", path: "src", output_mode: "content", -n: true)
```

**Output modes**:
- `files_with_matches` (default): File paths only
- `content`: Matching lines with context
- `count`: Match counts per file

**Options**:
- `-i`: Case insensitive
- `-n`: Show line numbers
- `-A`, `-B`, `-C`: Show context lines
- `glob`: Filter by file pattern
- `type`: Filter by file type (js, py, rb, etc.)

#### Glob Tool

Find files by pattern:

```yaml
finder:
  description: "File finder"
  model: "gpt-4"
  system_prompt: "Locate files"
  # Glob included by default
```

**Usage**:
```
Glob(pattern: "**/*.rb")
Glob(pattern: "src/**/*.{js,ts}")
Glob(pattern: "test_*.py", path: "tests/")
```

#### TodoWrite Tool

Track multi-step tasks:

```ruby
agent :planner do
  description "Task planner"
  model "gpt-4"
  system_prompt "Plan and track work"
  tools :Read, :Grep, :Glob, :TodoWrite  # Add TodoWrite explicitly
end
```

**Usage**:
```
TodoWrite(
  todos: [
    {content: "Read config", status: "completed", activeForm: "Reading config"},
    {content: "Parse data", status: "in_progress", activeForm: "Parsing data"},
    {content: "Write output", status: "pending", activeForm: "Writing output"}
  ]
)
```

**When to use**: Multi-step tasks where tracking progress helps.

#### Scratchpad Tools (Shared, Volatile)

Share work-in-progress data between agents in the same swarm. Scratchpad is **volatile** (in-memory only, cleared when swarm ends) and **shared** (all agents access the same scratchpad).

```ruby
agent :processor do
  description "Data processor"
  model "gpt-4"
  system_prompt "Process and store intermediate results"
  # Scratchpad tools included by default
end
```

**ScratchpadWrite** - Store temporary data:
```
ScratchpadWrite(file_path: "task/batch1/result", content: "...", title: "Batch 1 Result")
```

**ScratchpadRead** - Read shared data:
```
ScratchpadRead(file_path: "task/batch1/result")
# Returns: Content without line numbers (simpler than Memory tools)
```

**ScratchpadList** - List all entries:
```
ScratchpadList(prefix: "task/")  # List entries under task/
ScratchpadList()                 # List all entries
```

**Features**:
- **Volatile**: Cleared when swarm ends (no persistence)
- **Shared**: All agents access the same scratchpad
- **Simple**: Just write, read, list (no edit/grep/glob)
- **Fast**: In-memory only, no disk I/O

**Use cases**:
- Sharing intermediate results between agents
- Coordinating parallel work
- Passing data in delegation chains

#### Memory Tools (Per-Agent, Persistent)

Build persistent knowledge over time with per-agent memory. Memory is **persistent** (survives sessions) and **isolated** (each agent has its own memory).

```ruby
agent :learning_assistant do
  description "Assistant that learns over time"
  model "gpt-4"
  system_prompt "Build knowledge in memory"

  # Configure persistent memory
  memory do
    adapter :filesystem  # default, optional
    directory ".swarm/learning-assistant"  # required
  end
  # Memory tools automatically added when memory is configured
end
```

**YAML equivalent:**
```yaml
learning_assistant:
  description: "Assistant that learns over time"
  model: "gpt-4"
  memory:
    adapter: filesystem  # optional
    directory: .swarm/learning-assistant  # required
```

**MemoryWrite** - Store knowledge permanently:
```
MemoryWrite(file_path: "concepts/ruby/classes.md", content: "...", title: "Ruby Classes")
```

**MemoryRead** - Recall knowledge (with line numbers):
```
MemoryRead(file_path: "concepts/ruby/classes.md")
# Returns:
#      1→---
#      2→type: concept
#      3→...
```

**MemoryEdit** - Update knowledge:
```
MemoryEdit(file_path: "facts/user.md", old_string: "...", new_string: "...")
```

**MemoryGlob** - Browse knowledge by pattern:
```
MemoryGlob(pattern: "concepts/ruby/**")    # All Ruby concepts
MemoryGlob(pattern: "skills/**")            # All skills
```

**MemoryGrep** - Search knowledge by content:
```
MemoryGrep(pattern: "authentication", output_mode: "content")
```

**MemoryDelete** - Remove obsolete knowledge:
```
MemoryDelete(file_path: "concepts/outdated.md")
```

**Features**:
- **Persistent**: Saved to disk, survives sessions
- **Per-agent**: Each agent has isolated memory
- **Comprehensive**: Full edit/search/browse capabilities
- **Ordered**: Search results show most recent first

**Use cases**:
- Learning agents that build expertise over time
- Agents that remember user preferences
- Agents that accumulate domain knowledge
- Persisting results across swarm restarts

#### Think Tool

Enable explicit reasoning and planning:

```ruby
agent :problem_solver do
  description "Problem solver"
  model "gpt-4"
  system_prompt "Use the Think tool frequently to reason through problems"
  tools :Read, :Grep, :Glob, :Think  # Add Think explicitly
end
```

**Usage**:
```
Think(thoughts: "Let me break this down: 1) Read the file, 2) Analyze structure, 3) Make changes")
Think(thoughts: "If we have 150 requests/sec and each takes 20ms, that's 150 * 0.02 = 3 seconds")
```

**Why use Think**:
- **Better reasoning**: Explicit thinking leads to better outcomes
- **Step-by-step planning**: Break complex tasks into manageable steps
- **Arithmetic accuracy**: Work through calculations methodically
- **Context maintenance**: Remember important details across multiple steps

**When to use**:
1. **Before starting tasks**: Understand the problem and create a plan
2. **For arithmetic**: Work through calculations step by step
3. **After sub-tasks**: Summarize progress and plan next actions
4. **When debugging**: Track investigation process
5. **For complex decisions**: Break down logic and options

**How it works**: The Think tool records thoughts as function calls in the conversation history. These create "attention sinks" that the model can reference throughout the task, leading to better reasoning than just thinking in the system prompt.

**Best practice**: Successful agents use Think 5-10 times per task on average. If you haven't used Think in the last 2-3 actions, you probably should.

**Example workflow**:
```
1. Think: "User wants X. Breaking into: 1) Read code, 2) Identify changes, 3) Implement, 4) Test"
2. Read relevant files
3. Think: "I see the structure. Key files are A, B. Need to modify B's function foo()"
4. Make changes
5. Think: "Changes made. Next: verify tests pass"
6. Run tests
7. Think: "Tests pass. Task complete."
```

#### WebFetch Tool

Fetch and analyze web content:

```ruby
agent :researcher do
  description "Web researcher"
  model "gpt-4"
  system_prompt "Research information from web sources"
  tools :Read, :Grep, :Glob, :WebFetch  # Add WebFetch explicitly
end
```

**Usage without LLM processing** (default):
```
WebFetch(url: "https://example.com/docs")
# Returns: Raw markdown conversion of the page
```

**Usage with LLM processing** (requires configuration):
```ruby
# First, configure WebFetch globally
SwarmSDK.configure do |config|
  config.webfetch_provider = "anthropic"
  config.webfetch_model = "claude-3-5-haiku-20241022"
end

# Then agents can use it with prompts
WebFetch(url: "https://example.com/api-docs", prompt: "List all available API endpoints")
# Returns: LLM's analysis of the page content
```

**Features**:
- Fetches web content and converts HTML to Markdown
- Optional LLM processing with user-defined prompts
- 15-minute cache to avoid redundant fetches
- Handles redirects and errors gracefully
- Supports custom providers and models via configuration

**HTML to Markdown conversion**:
- Uses `reverse_markdown` gem if installed (handles complex HTML, tables, etc.)
- Falls back to built-in converter for common HTML elements
- Always strips scripts and styles

**When to use**:
- Fetching API documentation
- Reading blog posts or articles
- Extracting information from web pages
- Researching technical content

**Disable specific default tools** (if needed):
```ruby
agent :agent_name do
  description "..."
  model "gpt-4"
  disable_default_tools [:Read, :Grep]  # Disable specific tools
end
```

```yaml
agent_name:
  description: "..."
  model: "gpt-4"
  disable_default_tools:  # Disable specific tools
    - Think
    - WebFetch
```

### 2.2 Default Tools

Some tools are included automatically:

```ruby
agent :agent_name do
  description "..."
  model "gpt-4"
  # These are included by default:
  # - Read, Grep, Glob (file operations)
  # - TodoWrite (task tracking)
  # - ScratchpadWrite, ScratchpadRead, ScratchpadEdit, ScratchpadMultiEdit, ScratchpadGlob, ScratchpadGrep (shared persistent storage)
  # - Think (explicit reasoning)

  # Add additional tools:
  tools :Write, :Edit, :Bash
end
```

**Disable default tools**:
```ruby
# Disable ALL default tools
agent :minimal_agent do
  description "Minimal agent"
  model "gpt-4"
  disable_default_tools true
  tools :Read  # Only Read available
end

# Disable SPECIFIC default tools
agent :selective_agent do
  description "Selective agent"
  model "gpt-4"
  disable_default_tools [:Read, :Grep]  # Disable these
  # Still has: Glob, Scratchpad tools
end
```

```yaml
# Disable ALL default tools
minimal_agent:
  description: "Minimal agent"
  model: "gpt-4"
  disable_default_tools: true
  tools:
    - Read       # Only Read available

# Disable SPECIFIC default tools
selective_agent:
  description: "Selective agent"
  model: "gpt-4"
  disable_default_tools:
    - Think
    - TodoWrite
```

**When to disable**: When you want precise control over agent capabilities.

### 2.3 Path Permissions

Control which files agents can access:

**Allow specific paths**:
```ruby
agent :backend_dev do
  description "Backend developer"
  model "gpt-4"
  directory "."
  tools :Write, :Edit

  permissions do
    tool(:Write).allow_paths "backend/**/*"
    tool(:Write).deny_paths "backend/secrets/**"
  end
end
```

**YAML equivalent**:
```yaml
backend_dev:
  description: "Backend developer"
  model: "gpt-4"
  directory: "."
  tools:
    - Write:
        allowed_paths:
          - "backend/**/*"
        denied_paths:
          - "backend/secrets/**"
    - Edit:
        allowed_paths:
          - "backend/**/*"
```

**How it works**:
1. Agent attempts to write to `backend/api/users.rb` → Allowed
2. Agent attempts to write to `backend/secrets/keys.rb` → Denied (explicit deny)
3. Agent attempts to write to `frontend/app.js` → Denied (not in allowed paths)

**Default behavior**: Write, Edit, and MultiEdit are restricted to `**/*` (everything in agent's directory) by default.

### 2.4 Command Permissions

Restrict which bash commands agents can run:

```ruby
agent :safe_executor do
  description "Safe command executor"
  model "gpt-4"
  tools :Bash

  permissions do
    tool(:Bash).allow_commands "ls", "pwd", "echo", "cat"
    tool(:Bash).deny_commands "rm", "dd", "sudo"
  end
end
```

**YAML**:
```yaml
safe_executor:
  description: "Safe command executor"
  model: "gpt-4"
  tools:
    - Bash:
        allowed_commands:
          - ls
          - pwd
          - echo
          - cat
        denied_commands:
          - rm
          - dd
          - sudo
```

**Why restrict commands**: Prevent agents from running dangerous operations.

### 2.5 All-Agents Permissions

Apply permissions to all agents at once:

**Ruby DSL**:
```ruby
SwarmSDK.build do
  name "Team"
  lead :dev

  all_agents do
    tools :Write, :Edit

    permissions do
      tool(:Write).allow_paths "src/**/*", "docs/**/*"
      tool(:Write).deny_paths "**/secrets/**"
    end
  end

  agent :dev do
    description "Developer"
    model "gpt-4"
    # Inherits all_agents permissions
  end

  agent :tester do
    description "Tester"
    model "gpt-4"
    # Also inherits all_agents permissions
  end
end
```

**YAML**:
```yaml
version: 2
swarm:
  name: "Team"
  lead: dev

  all_agents:
    tools:
      - Write:
          allowed_paths:
            - "src/**/*"
            - "docs/**/*"
          denied_paths:
            - "**/secrets/**"
      - Edit

  agents:
    dev:
      description: "Developer"
      model: "gpt-4"

    tester:
      description: "Tester"
      model: "gpt-4"
```

**Override for specific agents**:
```ruby
agent :admin do
  description "Admin with more access"
  model "gpt-4"

  permissions do
    tool(:Write).allow_paths "**/*"  # Overrides all_agents
  end
end
```

### 2.6 Bypass Permissions

Disable permission checking for trusted agents:

```ruby
agent :trusted_admin do
  description "Trusted admin"
  model "gpt-4"
  tools :Write, :Edit, :Bash
  bypass_permissions true  # No permission checks
end
```

**When to use**: Internal tools, admin agents, fully trusted scenarios.

**Warning**: Use sparingly - bypassed agents can modify any file and run any command.

---

## Part 3: Agent Collaboration

### 3.1 Basic Delegation

Agents collaborate by delegating work to specialists:

**Ruby DSL**:
```ruby
swarm = SwarmSDK.build do
  name "Code Review Team"
  lead :developer

  agent :developer do
    description "Writes code"
    model "gpt-4"
    system_prompt "You write code and send it for review"
    tools :Write, :Edit
    delegates_to :reviewer
  end

  agent :reviewer do
    description "Reviews code"
    model "claude-sonnet-4"
    system_prompt "You review code for bugs and improvements"
  end
end

result = swarm.execute("Write an email validation function and get it reviewed")
```

**YAML**:
```yaml
version: 2
swarm:
  name: "Code Review Team"
  lead: developer

  agents:
    developer:
      description: "Writes code"
      model: "gpt-4"
      system_prompt: "You write code and send it for review"
      tools:
        - Write
        - Edit
      delegates_to:
        - reviewer

    reviewer:
      description: "Reviews code"
      model: "claude-sonnet-4"
      system_prompt: "You review code for bugs and improvements"
```

**How delegation works**:
1. You send task to `developer`
2. Developer writes code using Write tool
3. Developer calls `WorkWithReviewer(message: "Review this code")`
4. Reviewer analyzes code and returns feedback
5. Developer receives feedback and can iterate
6. Developer returns final result to you

**The delegation tool**: When you configure `delegates_to: [reviewer]`, the developer automatically gets a `WorkWithReviewer` tool.

### 3.2 Multi-Level Delegation

Build hierarchical teams:

```ruby
swarm = SwarmSDK.build do
  name "Software Team"
  lead :architect

  agent :architect do
    description "Lead architect"
    model "gpt-4"
    system_prompt "You coordinate the team and break down work"
    delegates_to :backend, :frontend
  end

  agent :backend do
    description "Backend developer"
    model "gpt-4"
    system_prompt "You build APIs and databases"
    tools :Write, :Edit
    delegates_to :database, :tester
  end

  agent :frontend do
    description "Frontend developer"
    model "gpt-4"
    system_prompt "You build UI components"
    tools :Write, :Edit
    delegates_to :designer, :tester
  end

  agent :database do
    description "Database specialist"
    model "gpt-4"
    system_prompt "You design schemas and write migrations"
    tools :Write
  end

  agent :designer do
    description "UI designer"
    model "claude-sonnet-4"
    system_prompt "You design user interfaces"
  end

  agent :tester do
    description "QA engineer"
    model "claude-sonnet-4"
    system_prompt "You write tests and verify functionality"
    tools :Write
  end
end

result = swarm.execute("Build a user authentication system")
```

**Execution flow**:
1. Architect receives task
2. Architect delegates to backend: "Build auth API"
3. Backend delegates to database: "Design user schema"
4. Database designs schema, returns to backend
5. Backend delegates to tester: "Test auth endpoints"
6. Tester writes tests, returns to backend
7. Backend returns completed API to architect
8. Architect delegates to frontend: "Build login UI"
9. Frontend delegates to designer: "Design login form"
10. Designer creates design, returns to frontend
11. Frontend implements UI, returns to architect
12. Architect returns complete system to you

**Why multi-level delegation**: Complex tasks need specialized sub-teams.

### 3.3 Peer Collaboration

Agents at the same level can collaborate:

```yaml
version: 2
swarm:
  name: "Peer Collaboration"
  lead: backend

  agents:
    backend:
      description: "Backend developer"
      model: "gpt-4"
      system_prompt: "You build APIs"
      tools:
        - Write
      delegates_to:
        - frontend
        - database

    frontend:
      description: "Frontend developer"
      model: "gpt-4"
      system_prompt: "You build UI"
      tools:
        - Write
      delegates_to:
        - backend  # Can delegate back!
        - database

    database:
      description: "Database specialist"
      model: "gpt-4"
      system_prompt: "You design databases"
      tools:
        - Write
      delegates_to:
        - backend
        - frontend
```

**Use case**: Backend and frontend need to coordinate API contracts, database schema affects both.

**Note**: SwarmSDK prevents circular delegation (A → B → A) within a single task to avoid infinite loops.

### 3.4 Delegation Patterns

**Pattern 1: Linear Pipeline**
```
You → Planner → Coder → Tester → You
```

**Pattern 2: Hub and Spoke**
```
        ┌──→ Backend ──┐
You → Architect       → You
        └──→ Frontend ─┘
```

**Pattern 3: Specialist Pool**
```
           ┌──→ Database
           ├──→ Cache
Lead    ──┼──→ Security
           ├──→ Testing
           └──→ Docs
```

**Choosing a pattern**:
- **Linear**: Sequential tasks with clear order
- **Hub and Spoke**: Parallel tasks coordinated by lead
- **Specialist Pool**: Lead delegates to any specialist as needed

#### Delegation Isolation Modes

When multiple agents delegate to the same target agent, you can control whether they share conversation history or get isolated instances.

**Problem this solves**: Without isolation, multiple agents delegating to the same target share conversation history, causing context mixing. For example, if both `frontend` and `backend` delegate to `tester`, the tester's conversation includes both delegations mixed together, making it confusing.

**Solution: Isolated Instances (Default)**

By default, each delegator gets its own isolated instance:

```yaml
agents:
  tester:
    description: "Testing agent"
    # shared_across_delegations: false (default - isolated mode)

  frontend:
    description: "Frontend developer"
    delegates_to: [tester]  # Gets tester@frontend

  backend:
    description: "Backend developer"
    delegates_to: [tester]  # Gets tester@backend (separate instance)
```

**Result**:
- `frontend` → `tester@frontend` (isolated conversation)
- `backend` → `tester@backend` (separate isolated conversation)
- No context mixing between frontend and backend's testing conversations

**When to Use Shared Mode**

For agents that benefit from seeing all delegation contexts:

```yaml
agents:
  database:
    description: "Database coordination agent"
    shared_across_delegations: true  # Shared mode

  frontend:
    delegates_to: [database]

  backend:
    delegates_to: [database]
```

Both frontend and backend share the same database agent instance and conversation history.

**Use shared mode for:**
- Stateful coordination agents
- Database agents maintaining transaction state
- Agents that benefit from seeing all contexts

**Memory Sharing (Always Enabled)**

Regardless of isolation mode, **plugin storage is always shared** by base agent name:
- `tester@frontend` and `tester@backend` share the same SwarmMemory storage
- This allows delegation instances to share knowledge while maintaining separate conversations
- Best of both worlds: isolated conversations + shared memory

### 3.5 Markdown Agent Files

Define agents in separate markdown files for better organization:

**agents/backend.md**:
```markdown
---
description: "Backend developer specializing in Ruby on Rails"
model: "gpt-4"
tools:
  - Write
  - Edit
  - Bash
---

# Backend Developer

You are an expert backend developer specializing in Ruby on Rails.

## Responsibilities
- Build RESTful APIs
- Design database schemas
- Write tests
- Handle authentication

## Best Practices
- Follow Rails conventions
- Use strong parameters
- Write comprehensive tests
- Document API endpoints

## Tools
You have access to file operations and bash commands.
```

**Note**: Markdown agent files MUST include YAML frontmatter between `---` delimiters. The frontmatter contains description, model, tools, etc. Content after frontmatter becomes the system_prompt.

**Load in YAML**:
```yaml
version: 2
swarm:
  name: "Team"
  lead: backend

  agents:
    backend: "agents/backend.md"

    # Or with overrides:
    # backend:
    #   agent_file: "agents/backend.md"
    #   timeout: 120
```

**Why markdown files**:
- Better organization for complex prompts
- Version control friendly
- Easy to review and edit
- Supports rich formatting

**What goes in the file**: The markdown file contains both:
1. **Frontmatter** (YAML between `---` delimiters): description, model, tools, delegates_to, etc.
2. **System prompt** (content after frontmatter): Agent's instructions and behavior

You can override frontmatter settings in YAML using the hash format with `agent_file` key.

### 3.6 Delegation Tracking

SwarmSDK tracks which agents were involved:

```ruby
result = swarm.execute("Build auth system")

# See which agents participated (returns array of symbols)
puts result.agents_involved
# => [:architect, :backend, :database, :tester]

# Check if specific agent was involved
if result.agents_involved.include?(:reviewer)
  puts "Code was reviewed!"
end

# See logs organized by agent
result.logs.group_by { |log| log[:agent] }.each do |agent, logs|
  puts "#{agent}: #{logs.size} events"
end
```

**CLI output** shows delegation in real-time:
```
architect • thinking...
architect → backend: Build auth API

backend • thinking...
backend → database: Design user schema

database • thinking...
database • Complete

backend • Complete
architect • Complete
```

**Why tracking matters**: Understanding agent collaboration helps optimize team structure.

---

## Part 4: Hooks System

Hooks let you customize behavior at every step of execution.

### 4.1 Hook Events

SwarmSDK provides 13 hook events:

**Swarm Lifecycle**:
- `swarm_start` - When Swarm.execute is called (before first message)
- `swarm_stop` - When execution completes
- `first_message` - When first user message is sent

**Agent/LLM**:
- `user_prompt` - Before sending message to LLM
- `agent_step` - After agent makes intermediate response with tool calls
- `agent_stop` - After agent completes (no more tool calls)

**Tool Usage**:
- `pre_tool_use` - Before tool execution (can block)
- `post_tool_use` - After tool execution

**Delegation**:
- `pre_delegation` - Before delegating to another agent
- `post_delegation` - After delegation completes

**Context**:
- `context_warning` - When context usage crosses threshold (80%, 90%)

**Debug**:
- `breakpoint_enter` - When entering interactive debugging
- `breakpoint_exit` - When exiting debugging

### 4.2 Hook Actions

Hooks can take different actions by returning specific values:

**Continue (default)**: Return nil or nothing
```ruby
hook :pre_tool_use do |ctx|
  puts "Tool: #{ctx.tool_call.name}"
  # Continues execution
end
```

**Halt**: Stop execution with error
```ruby
hook :pre_tool_use, matcher: "Bash" do |ctx|
  if ctx.tool_call.parameters[:command].include?("rm -rf")
    SwarmSDK::Hooks::Result.halt("Dangerous command blocked")
  end
end
```

**Replace**: Modify tool result
```ruby
hook :post_tool_use do |ctx|
  if ctx.tool_result.content.length > 10000
    SwarmSDK::Hooks::Result.replace("Content truncated (too long)")
  end
end
```

**Reprompt**: Continue execution with new prompt (swarm_stop only)
```ruby
hook :swarm_stop do |ctx|
  result = ctx.metadata[:result]
  if result.content.include?("TODO")
    SwarmSDK::Hooks::Result.reprompt("Complete all TODOs before finishing")
  end
end
```

**Finish Agent**: End current agent's turn and return control
```ruby
hook :agent_step do |ctx|
  if ctx.metadata[:tool_calls].size > 10
    SwarmSDK::Hooks::Result.finish_agent("Too many tool calls")
  end
end
```

**Finish Swarm**: End entire swarm execution immediately
```ruby
hook :pre_tool_use do |ctx|
  if ctx.tool_call.name == "Bash" && ctx.tool_call.parameters[:command] == "shutdown"
    SwarmSDK::Hooks::Result.finish_swarm("Emergency shutdown requested")
  end
end
```

### 4.3 Ruby Block Hooks

Define hooks as Ruby blocks in the DSL:

**Swarm-level hook**:
```ruby
swarm = SwarmSDK.build do
  name "Team"
  lead :dev

  # Hook applies to entire swarm
  hook :swarm_start do |ctx|
    puts "Starting: #{ctx.metadata[:prompt]}"
  end

  agent :dev do
    description "Developer"
    model "gpt-4"
  end
end
```

**All-agents hook**:
```ruby
SwarmSDK.build do
  name "Team"
  lead :dev

  all_agents do
    # Hook applies to all agents
    hook :pre_tool_use, matcher: "Write|Edit" do |ctx|
      puts "[#{ctx.agent_name}] Modifying: #{ctx.tool_call.parameters[:file_path]}"
    end
  end

  agent :dev do
    description "Developer"
    model "gpt-4"
    tools :Write, :Edit
  end
end
```

**Agent-specific hook**:
```ruby
agent :dev do
  description "Developer"
  model "gpt-4"
  tools :Write, :Edit

  # Hook applies only to this agent
  hook :post_tool_use, matcher: "Write" do |ctx|
    if ctx.tool_result.success?
      puts "File created: #{ctx.tool_result.tool_name}"
    end
  end
end
```

**Hook with matcher**:
```ruby
agent :dev do
  description "Developer"
  model "gpt-4"
  tools :Write, :Edit, :Bash

  # Only runs for Bash tool
  hook :pre_tool_use, matcher: "Bash" do |ctx|
    cmd = ctx.tool_call.parameters[:command]
    if cmd.start_with?("rm ")
      SwarmSDK::Hooks::Result.halt("rm command not allowed")
    end
  end
end
```

### 4.4 Shell Command Hooks (YAML)

Define hooks as shell commands in YAML:

```yaml
version: 2
swarm:
  name: "Team with Hooks"
  lead: dev

  hooks:
    swarm_start:
      - type: command
        command: "echo 'Swarm started' >> /tmp/swarm.log"

  all_agents:
    hooks:
      pre_tool_use:
        - matcher: "Write|Edit"
          type: command
          command: "scripts/validate_write.sh"
          timeout: 10

  agents:
    dev:
      description: "Developer"
      model: "gpt-4"
      tools:
        - Write
        - Edit
      hooks:
        post_tool_use:
          - matcher: "Write"
            type: command
            command: "scripts/notify_write.sh"
```

**Hook script receives JSON on stdin**:

**scripts/validate_write.sh**:
```bash
#!/bin/bash
# Read JSON from stdin
INPUT=$(cat)

# Extract tool and parameters
TOOL=$(echo "$INPUT" | jq -r '.tool')
FILE=$(echo "$INPUT" | jq -r '.parameters.file_path')

# Validate
if [[ "$FILE" == *"production"* ]]; then
  echo "Cannot write to production" >&2
  exit 2  # Halt with error
fi

# Allow
exit 0
```

**Exit codes**:
- `0`: Success, continue execution
- `2`: Halt execution with error from stderr
- Other: Non-blocking warning

### 4.5 Hook Context

Hooks receive a context object with event-specific data:

**pre_tool_use context**:
```ruby
hook :pre_tool_use do |ctx|
  ctx.event           # => :pre_tool_use
  ctx.agent_name      # => "developer"
  ctx.swarm           # => Swarm instance

  # Tool call info
  ctx.tool_call.id         # => "call_abc123"
  ctx.tool_call.name       # => "Write"
  ctx.tool_call.parameters # => {file_path: "...", content: "..."}

  # Metadata (event-specific)
  ctx.metadata[:message_count]  # Number of messages so far
end
```

**post_tool_use context**:
```ruby
hook :post_tool_use do |ctx|
  ctx.tool_result.tool_call_id  # => "call_abc123"
  ctx.tool_result.tool_name     # => "Write"
  ctx.tool_result.content       # Tool output
  ctx.tool_result.success?      # => true/false
end
```

**swarm_stop context**:
```ruby
hook :swarm_stop do |ctx|
  ctx.metadata[:result]          # Final Result object
  ctx.metadata[:success]         # => true/false
  ctx.metadata[:duration]        # Execution time
  ctx.metadata[:total_cost]      # Total cost
  ctx.metadata[:agents_involved] # Array of agent names
end
```

### 4.6 Breakpoint Debugging

Insert interactive breakpoints for debugging:

```ruby
agent :dev do
  description "Developer"
  model "gpt-4"
  tools :Write

  hook :post_tool_use, matcher: "Write" do |ctx|
    # Drop into IRB to inspect context
    require 'irb'
    binding.irb
  end
end
```

**In the IRB session**:
```ruby
irb(main)> ctx.tool_result.content
# => "class NewClass\n..."

irb(main)> ctx.agent_name
# => "dev"

irb(main)> exit  # Continue execution
```

**When to use**: Debugging complex workflows, inspecting tool results, understanding agent behavior.

### 4.7 Practical Hook Examples

**Example 1: Usage Tracking**
```ruby
all_agents do
  hook :agent_stop do |ctx|
    File.open("usage.log", "a") do |f|
      f.puts "#{ctx.agent_name},#{ctx.metadata[:usage][:total_tokens]},#{ctx.metadata[:usage][:cost]}"
    end
  end
end
```

**Example 2: Dangerous Command Prevention**
```ruby
agent :executor do
  description "Command executor"
  model "gpt-4"
  tools :Bash

  hook :pre_tool_use, matcher: "Bash" do |ctx|
    cmd = ctx.tool_call.parameters[:command]

    dangerous = ["rm -rf", "dd if=", "sudo", ">", "mkfs"]
    if dangerous.any? { |d| cmd.include?(d) }
      SwarmSDK::Hooks::Result.halt("Dangerous command blocked: #{cmd}")
    end
  end
end
```

**Example 3: Automatic Code Review**
```ruby
agent :dev do
  description "Developer"
  model "gpt-4"
  tools :Write, :Edit
  delegates_to :reviewer

  hook :post_tool_use, matcher: "Write|Edit" do |ctx|
    if ctx.tool_result.success? && ctx.tool_call.parameters[:file_path].end_with?(".rb")
      # Automatically send for review
      SwarmSDK::Hooks::Result.finish_agent("Code written, delegating to reviewer")
    end
  end
end
```

**Example 4: Context Warning Handler**
```ruby
all_agents do
  hook :context_warning do |ctx|
    percentage = ctx.metadata[:percentage]

    if percentage.to_f > 90
      # Emergency: Finish agent to prevent context overflow
      SwarmSDK::Hooks::Result.finish_agent("Context limit reached (#{percentage})")
    else
      # Just log the warning
      puts "⚠️  Context usage: #{percentage}"
    end
  end
end
```

---

## Part 5: Node Workflows

Node workflows enable multi-stage pipelines where different agent teams handle each stage.

### 5.1 Basic Node Workflow

**Concept**: Each node is a mini-swarm execution stage:

```ruby
swarm = SwarmSDK.build do
  name "Development Pipeline"

  # Define agents (shared across nodes)
  agent :planner do
    description "Plans work"
    model "gpt-4"
    system_prompt "Break down tasks into steps"
  end

  agent :coder do
    description "Writes code"
    model "gpt-4"
    system_prompt "Implement features"
    tools :Write, :Edit
  end

  agent :tester do
    description "Tests code"
    model "claude-sonnet-4"
    system_prompt "Write and run tests"
    tools :Write, :Bash
  end

  # Define nodes (execution stages)
  node :planning do
    agent(:planner)
  end

  node :implementation do
    agent(:coder)
    depends_on :planning  # Depends on planning
  end

  node :testing do
    agent(:tester)
    depends_on :implementation  # Depends on implementation
  end

  # Start from planning
  start_node :planning
end

result = swarm.execute("Build a user authentication system")
```

**Execution flow**:
1. Planning node runs with planner agent
2. Planner creates a plan
3. Implementation node runs with coder agent
4. Coder receives plan and implements it
5. Testing node runs with tester agent
6. Tester receives implementation and tests it
7. Final result returned

**Why nodes**: Different stages need different agent teams and can transform data between stages.

### 5.2 Node Dependencies

Nodes can depend on multiple previous nodes:

```ruby
node :planning do
  agent(:planner)
end

node :frontend_impl do
  agent(:frontend_dev)
  depends_on :planning
end

node :backend_impl do
  agent(:backend_dev)
  depends_on :planning
end

node :integration do
  agent(:integration_tester)
  depends_on :frontend_impl, :backend_impl  # Waits for both
end
```

**Execution order**:
1. planning
2. frontend_impl and backend_impl (parallel conceptually, but sequential in execution)
3. integration (after both complete)

**Note**: All node dependencies use `depends_on`:
- `depends_on :node` - Single dependency, receives that node's output
- `depends_on :node1, :node2` - Multiple dependencies, receives hash of results

### 5.3 Input Transformers

Transform data flowing into a node:

**Ruby transformer**:
```ruby
node :implementation do
  agent(:coder)
  depends_on :planning

  # Transform planning output before sending to coder
  input do |ctx|
    plan = ctx.content

    "Here is the plan:\n#{plan}\n\nImplement step 1 first: #{extract_first_step(plan)}"
  end
end

def extract_first_step(plan)
  plan.lines.grep(/^\d+\./).first
end
```

**Context object**:
```ruby
input do |ctx|
  ctx.content              # Previous node's output
  ctx.original_prompt      # Original user prompt
  ctx.previous_result      # Full Result object from previous node
  ctx.all_results          # Hash of all completed nodes
  ctx.node_name            # Current node name
  ctx.dependencies         # Array of dependency node names
end
```

**Use cases**:
- Extracting specific information
- Formatting data for the next stage
- Adding instructions or context
- Filtering large outputs

### 5.4 Output Transformers

Transform data flowing out of a node:

```ruby
node :planning do
  agent(:planner)

  # Extract just the steps from planner's response
  output do |ctx|
    response = ctx.content
    response.scan(/^\d+\.\s+(.+)$/).flatten.join("\n")
  end
end
```

**Context object**:
```ruby
output do |ctx|
  ctx.content         # Current node's result content
  ctx.result          # Full Result object
  ctx.original_prompt # Original user prompt
  ctx.all_results     # Hash of all completed nodes
  ctx.node_name       # Current node name
end
```

**Use cases**:
- Extracting specific data formats
- Summarizing long outputs
- Converting between formats
- Preparing data for next node

### 5.5 Bash Transformers

Use bash scripts as transformers:

**Input transformer**:
```ruby
node :processor do
  agent(:processor)
  depends_on :analyzer

  input_command "scripts/prepare_data.sh", timeout: 30
end
```

**scripts/prepare_data.sh**:
```bash
#!/bin/bash
# Receives previous node output on stdin

# Read input
INPUT=$(cat)

# Process
PROCESSED=$(echo "$INPUT" | jq '.results[] | select(.score > 80)')

# Output
echo "$PROCESSED"
```

**Bash transformer exit codes**:
- **Exit 0**: Use stdout as transformed content
- **Exit 1**: Skip node execution, pass input unchanged
- **Exit 2**: Halt workflow with error from stderr

**Example - Skip execution conditionally**:
```bash
#!/bin/bash
INPUT=$(cat)

# Check if input is empty
if [ -z "$INPUT" ]; then
  echo "No data to process" >&2
  exit 1  # Skip this node
fi

# Process normally
echo "$INPUT" | process_data
exit 0
```

**Example - Halt on error**:
```bash
#!/bin/bash
INPUT=$(cat)

# Validate input
if ! echo "$INPUT" | jq . > /dev/null 2>&1; then
  echo "Invalid JSON input" >&2
  exit 2  # Halt workflow
fi

echo "$INPUT" | jq '.data'
exit 0
```

### 5.6 Agent-Less Nodes

Nodes can run pure computation without LLM:

```ruby
node :data_extraction do
  # No agent - just computation

  input do |ctx|
    # Input transformer runs as normal
    ctx.content
  end

  # The "execution" is just passing through

  output do |ctx|
    # Output transformer does the work
    data = ctx.content
    extract_key_metrics(data)
  end
end

def extract_key_metrics(text)
  {
    word_count: text.split.size,
    line_count: text.lines.size,
    char_count: text.length
  }.to_json
end
```

**Output transformer with bash**:
```ruby
node :json_processing do
  output_command "jq '.items[] | {id, name}'"
end
```

**When to use agent-less nodes**:
- Data transformation
- Format conversion
- Validation
- Extraction
- Any non-LLM computation

**Cost savings**: Agent-less nodes consume no tokens or API calls.

### 5.7 NodeContext API

Access comprehensive workflow state:

**Multiple dependencies**:
```ruby
node :merge do
  agent(:merger)
  depends_on :frontend, :backend

  input do |ctx|
    # previous_result is a hash for multiple dependencies
    frontend_result = ctx.all_results[:frontend]
    backend_result = ctx.all_results[:backend]

    "Merge these components:\n\nFrontend:\n#{frontend_result.content}\n\nBackend:\n#{backend_result.content}"
  end
end
```

**Access any previous node**:
```ruby
output do |ctx|
  # Access specific node results
  planning_content = ctx.all_results[:planning].content

  # Include original prompt
  "Completed: #{ctx.original_prompt}\n\nPlan was: #{planning_content}\n\nResult: #{ctx.content}"
end
```

**Check previous node success**:
```ruby
input do |ctx|
  if ctx.previous_result.success?
    ctx.content
  else
    "Previous step failed, attempting recovery: #{ctx.previous_result.error.message}"
  end
end
```

**Control Flow Methods**:

NodeContext provides three methods for dynamic workflow control. Input and output blocks are automatically converted to lambdas, which means you can use `return` statements for clean early exits.

**1. goto_node - Jump to any node**:
```ruby
output do |ctx|
  # Using return for early exit (clean and natural)
  return ctx.goto_node(:revision, content: ctx.content) if needs_revision?(ctx.content)

  ctx.content  # Continue to next node normally
end
```

**2. halt_workflow - Stop entire workflow**:
```ruby
output do |ctx|
  # Using return for early exit
  return ctx.halt_workflow(content: ctx.content) if converged?(ctx.content)

  ctx.content  # Continue to next node
end
```

**3. skip_execution - Skip node's LLM call** (input transformers only):
```ruby
input do |ctx|
  cached = check_cache(ctx.content)

  # Using return for early exit when cached
  return ctx.skip_execution(content: cached) if cached

  ctx.content  # Execute node normally
end
```

**Why `return` works safely**: Input and output blocks are automatically converted to lambdas, where `return` only exits the transformer block, not your entire program. This enables natural Ruby control flow patterns.

**Creating loops with goto_node**:
```ruby
node :reasoning do
  agent(:thinker, reset_context: false)  # Preserve context across iterations

  output do |ctx|
    # Using return for early exit when max iterations reached
    return ctx.halt_workflow(content: "Max iterations reached") if ctx.all_results.size > 10

    ctx.goto_node(:reflection, content: ctx.content)
  end
end

node :reflection do
  agent(:critic, reset_context: false)

  output do |ctx|
    # Loop back to reasoning
    ctx.goto_node(:reasoning, content: ctx.content)
  end
end

start_node :reasoning
```

**Note:** All control flow methods validate that `content` is not nil. If a node fails with an error, check for errors before calling goto_node:

```ruby
output do |ctx|
  # Using return for early exit on error
  return ctx.halt_workflow(content: "Error: #{ctx.error.message}") if ctx.error

  ctx.goto_node(:next_node, content: ctx.content)
end
```

### 5.8 Context Preservation Across Nodes

By default, agents get fresh conversation context in each node (`reset_context: true`). To preserve an agent's conversation history across nodes, use `reset_context: false`:

```ruby
agent :architect do
  model "gpt-4"
  system_prompt "You design systems"
end

node :planning do
  agent(:architect, reset_context: false)  # Preserve context
end

node :revision do
  agent(:architect, reset_context: false)  # Same instance - remembers planning!
  depends_on :planning
end
```

**When to preserve context:**
- Iterative refinement workflows
- Agent builds on its previous decisions
- Chain of thought reasoning across stages
- Self-reflection loops

**When to reset context (default):**
- Independent validation/review
- Fresh perspective needed
- Memory management in long workflows
- Different roles for same agent in different stages

### 5.9 Complex Workflow Example

**Multi-stage development pipeline**:

```ruby
swarm = SwarmSDK.build do
  name "Full Development Pipeline"

  # Define all agents
  agent :product_manager do
    description "Product manager"
    model "gpt-4"
    system_prompt "Define requirements and priorities"
  end

  agent :architect do
    description "Software architect"
    model "gpt-4"
    system_prompt "Design system architecture"
  end

  agent :backend_dev do
    description "Backend developer"
    model "gpt-4"
    system_prompt "Implement backend services"
    tools :Write, :Edit
  end

  agent :frontend_dev do
    description "Frontend developer"
    model "gpt-4"
    system_prompt "Implement user interface"
    tools :Write, :Edit
  end

  agent :qa_engineer do
    description "QA engineer"
    model "claude-sonnet-4"
    system_prompt "Test and verify implementation"
    tools :Write, :Bash
  end

  # Stage 1: Requirements gathering
  node :requirements do
    agent(:product_manager)

    output do |ctx|
      # Extract structured requirements
      requirements = ctx.content
      {
        functional: extract_section(requirements, "Functional Requirements"),
        nonfunctional: extract_section(requirements, "Non-Functional Requirements"),
        priority: extract_section(requirements, "Priority")
      }.to_json
    end
  end

  # Stage 2: Architecture design
  node :architecture do
    agent(:architect)
    depends_on :requirements

    input do |ctx|
      reqs = JSON.parse(ctx.content)
      "Design architecture for these requirements:\n\n#{reqs['functional']}"
    end
  end

  # Stage 3a: Backend implementation
  node :backend do
    agent(:backend_dev)
    depends_on :architecture

    input do |ctx|
      arch = ctx.content
      "Implement backend based on this architecture:\n#{arch}\n\nFocus on API endpoints."
    end
  end

  # Stage 3b: Frontend implementation
  node :frontend do
    agent(:frontend_dev)
    depends_on :architecture

    input do |ctx|
      arch = ctx.content
      "Implement frontend based on this architecture:\n#{arch}\n\nFocus on user flows."
    end
  end

  # Stage 4: Integration testing
  node :testing do
    agent(:qa_engineer)
    depends_on :backend, :frontend

    input do |ctx|
      backend = ctx.all_results[:backend].content
      frontend = ctx.all_results[:frontend].content

      "Test integration:\n\nBackend endpoints: #{extract_endpoints(backend)}\n\nFrontend flows: #{extract_flows(frontend)}"
    end
  end

  # Stage 5: Final report (agent-less)
  node :report do
    depends_on :testing

    output do |ctx|
      testing_result = ctx.content
      requirements = ctx.all_results[:requirements].content

      generate_project_report(
        requirements: requirements,
        testing: testing_result,
        original_task: ctx.original_prompt
      )
    end
  end

  start_node :requirements
end

result = swarm.execute("Build a task management application")
```

**Execution**:
1. Requirements → Product manager gathers requirements
2. Architecture → Architect designs system (receives requirements)
3. Backend + Frontend → Parallel implementation (both receive architecture)
4. Testing → QA tests integration (receives both implementations)
5. Report → Generates final report (agent-less, receives all results)

---

## Part 6: Advanced Configuration

### 6.1 MCP Server Integration

Connect to external tools and services using Model Context Protocol:

**stdio transport** (local processes):
```ruby
agent :filesystem_user do
  description "Uses filesystem MCP server"
  model "gpt-4"
  system_prompt "You can access files via MCP"

  mcp_server :filesystem,
    type: :stdio,
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/allowed/path"]
end
```

**YAML equivalent**:
```yaml
filesystem_user:
  description: "Uses filesystem MCP server"
  model: "gpt-4"
  system_prompt: "You can access files via MCP"
  mcp_servers:
    - name: filesystem
      type: stdio
      command: npx
      args:
        - "-y"
        - "@modelcontextprotocol/server-filesystem"
        - "/allowed/path"
```

**SSE transport** (server-sent events):
```ruby
mcp_server :web_service,
  type: :sse,
  url: "https://api.example.com/mcp",
  headers: {
    authorization: "Bearer #{ENV['API_TOKEN']}"
  }
```

**HTTP transport** (streamable):
```yaml
mcp_servers:
  - name: api_service
    type: http
    url: "https://api.example.com/mcp"
    timeout: 60
```

**Tool access**: MCP tools are available as `mcp__server_name__tool_name`:
```
# Agent can call:
mcp__filesystem__read_file(path: "/allowed/path/file.txt")
mcp__web_service__search(query: "...")
```

### 6.2 Custom Providers and Base URLs

Use custom LLM providers:

**OpenRouter**:
```ruby
agent :openrouter_agent do
  description "Uses OpenRouter"
  model "anthropic/claude-3-opus"
  provider "openai"  # OpenRouter is OpenAI-compatible
  base_url "https://openrouter.ai/api/v1"
  headers authorization: "Bearer #{ENV['OPENROUTER_KEY']}"
end
```

**Local LLM (Ollama)**:
```yaml
local_agent:
  description: "Local LLM via Ollama"
  model: "llama2"
  provider: "openai"
  base_url: "http://localhost:11434/v1"
  assume_model_exists: true  # Skip model validation
```

**Custom proxy**:
```ruby
agent :proxied do
  description "Through corporate proxy"
  model "gpt-4"
  provider "openai"
  base_url "https://internal-proxy.company.com/openai/v1"
  headers {
    "X-API-Key" => ENV['INTERNAL_KEY'],
    "X-Department" => "engineering"
  }
end
```

**When to use base_url**: Custom deployments, proxies, local models, alternative providers.

### 6.3 Context Window Management

**Override context window**:
```ruby
agent :large_context do
  description "Large context agent"
  model "gpt-4-turbo"
  context_window 128000  # Override default
end
```

**Why override**: Custom models, fine-tuned models, or correcting registry info.

**Context warnings**:
SwarmSDK automatically warns when context usage crosses thresholds (80%, 90%):

```ruby
all_agents do
  hook :context_warning do |ctx|
    percentage = ctx.metadata[:percentage].to_f

    case
    when percentage > 90
      puts "🚨 Critical: #{percentage}% context used"
      SwarmSDK::Hooks::Result.finish_agent("Context limit reached")
    when percentage > 80
      puts "⚠️  Warning: #{percentage}% context used"
    else
      puts "ℹ️  Info: #{percentage}% context used"
    end
  end
end
```

### 6.4 Context Compaction

SwarmSDK can automatically compact context when approaching limits:

**Enable compaction** (planned feature):
```ruby
agent :auto_compacting do
  description "Auto-compacts context"
  model "gpt-4"
  context_compaction enabled: true, threshold: 80
end
```

**Manual compaction strategies**:

1. **Summarize old messages**:
```ruby
hook :context_warning do |ctx|
  if ctx.metadata[:percentage].to_f > 80
    # Summarize conversation history
    SwarmSDK::Hooks::Result.replace("Summary: #{summarize(ctx.metadata[:history])}")
  end
end
```

2. **Remove intermediate tool calls**:
```ruby
hook :agent_step do |ctx|
  # Keep only final response, remove intermediate steps
  if ctx.metadata[:message_count] > 20
    SwarmSDK::Hooks::Result.finish_agent("Compacting context")
  end
end
```

### 6.5 Rate Limiting

Control API concurrency per agent:

**Per-agent concurrency**:
```ruby
agent :parallel_worker do
  description "Parallel task worker"
  model "gpt-4"
  max_concurrent_tools 5  # Max 5 concurrent tool calls for this agent
end
```

**YAML**:
```yaml
parallel_worker:
  description: "Parallel task worker"
  model: "gpt-4"
  max_concurrent_tools: 5
```

**Default values**:
- Global concurrency: 50 concurrent API calls (across entire swarm)
- Local concurrency: 10 concurrent tools per agent

**When to adjust**:
- Lower `max_concurrent_tools` for rate-limited APIs
- Higher for better parallelism (if API supports it)
- Tune based on API quotas and performance

**Note**: Global concurrency cannot be configured via DSL or YAML - it uses the default of 50. For per-agent control, use `max_concurrent_tools`.

### 6.6 Timeout Configuration

Control how long operations can run:

```ruby
agent :quick_responder do
  description "Fast responses required"
  model "gpt-4"
  timeout 30  # 30 second timeout for LLM calls
end
```

**Default timeout**: 300 seconds (5 minutes)

**When to adjust**:
- Lower for simple tasks requiring quick responses
- Higher for reasoning models (o1, etc.) that think longer
- Set based on task complexity

### 6.7 LLM Parameters

Tune model behavior:

**Temperature and top_p**:
```ruby
agent :creative do
  description "Creative writer"
  model "gpt-4"
  parameters temperature: 1.5, top_p: 0.95
end

agent :analytical do
  description "Analytical thinker"
  model "claude-sonnet-4"
  parameters temperature: 0.3, top_p: 0.9
end
```

**YAML**:
```yaml
creative:
  description: "Creative writer"
  model: "gpt-4"
  parameters:
    temperature: 1.5
    top_p: 0.95
    max_tokens: 4000
```

**Common parameters**:
- `temperature` (0.0-2.0): Randomness (higher = more creative)
- `top_p` (0.0-1.0): Diversity (higher = more diverse)
- `max_tokens`: Response length limit
- `presence_penalty`, `frequency_penalty`: Repetition control

**Parameter effects**:
```
Temperature 0.0-0.3  → Deterministic, focused, consistent
Temperature 0.7-1.0  → Balanced, natural
Temperature 1.2-2.0  → Creative, diverse, unpredictable
```

### 6.8 API Versions (Responses API)

Use Anthropic's Responses API (extended thinking):

```ruby
agent :deep_thinker do
  description "Deep reasoning agent"
  model "claude-sonnet-4"
  provider "anthropic"
  api_version "v1/responses"  # Use Responses API
  parameters thinking: { type: "enabled", budget_tokens: 10000 }
end
```

**YAML**:
```yaml
deep_thinker:
  description: "Deep reasoning agent"
  model: "claude-sonnet-4"
  provider: "anthropic"
  api_version: "v1/responses"
  parameters:
    thinking:
      type: "enabled"
      budget_tokens: 10000
```

**When to use**: Tasks requiring extended reasoning, complex problem-solving.

**Note**: Only works with compatible providers (Anthropic).

### 6.9 Assume Model Exists

Skip model validation for custom/unknown models:

```ruby
agent :custom_model do
  description "Uses custom model"
  model "my-finetuned-gpt-4"
  provider "openai"
  base_url "https://api.example.com/v1"
  assume_model_exists true  # Don't validate model
end
```

**When to use**:
- Custom fine-tuned models
- Local models
- New models not in SwarmSDK registry
- Proxy with model name translation

**Trade-off**: Disables context tracking and model-specific optimizations.

---

## Part 7: Production Features

### 7.1 Structured Logging

SwarmSDK emits structured JSON logs for all events:

```ruby
result = swarm.execute("Build API") do |log_entry|
  # log_entry is a hash with structured data
  case log_entry[:type]
  when "swarm_start"
    logger.info("Swarm started: #{log_entry[:swarm_name]}")

  when "agent_step"
    logger.info("Agent #{log_entry[:agent]} made #{log_entry[:tool_calls].size} tool calls")

  when "tool_call"
    logger.debug("Tool: #{log_entry[:tool]} with #{log_entry[:arguments]}")

  when "agent_stop"
    logger.info("Agent #{log_entry[:agent]} completed")
  end
end
```

**Log types**:
- `swarm_start`, `swarm_stop` - Swarm lifecycle
- `user_prompt` - User messages
- `agent_step`, `agent_stop` - Agent responses
- `tool_call`, `tool_result` - Tool execution
- `agent_delegation`, `delegation_result`, `delegation_error` - Agent delegation
- `node_start`, `node_stop` - Node workflow stages
- `model_lookup_warning` - Model validation issues
- `context_limit_warning` - Context usage warnings

**Log entry structure**:
```ruby
{
  type: "agent_step",
  agent: "backend",
  model: "gpt-4",
  content: "I'll implement the API...",
  tool_calls: [
    {id: "call_123", name: "Write", arguments: {...}}
  ],
  usage: {
    prompt_tokens: 1200,
    completion_tokens: 450,
    total_tokens: 1650,
    cost: 0.0825
  },
  timestamp: "2024-01-15T10:30:45Z"
}
```

### 7.2 Token Usage and Cost Tracking

Track usage and costs per agent:

```ruby
result = swarm.execute("Task")

# Overall metrics
puts "Total tokens: #{result.total_tokens}"
puts "Total cost: $#{result.total_cost}"
puts "LLM requests: #{result.llm_requests}"
puts "Tool calls: #{result.tool_calls_count}"
puts "Duration: #{result.duration}s"

# Agent breakdown (from logs)
result.logs.select { |log| log[:type] == "agent_stop" }.each do |log|
  agent = log[:agent]
  usage = log[:usage]
  puts "#{agent}: #{usage[:total_tokens]} tokens, $#{usage[:cost]}"
end
```

**Real-time tracking**:
```ruby
total_cost = 0.0

swarm.execute("Task") do |log|
  if log[:usage]
    total_cost += log[:usage][:cost]
    puts "Running cost: $#{total_cost.round(4)}"
  end
end
```

**Cost optimization tips**:
- Use smaller models for simple tasks (claude-haiku vs opus)
- Lower temperature reduces token usage
- Set max_tokens to limit responses
- Use agent-less nodes for computation
- Cache results in scratchpad

### 7.3 Error Handling and Recovery

Handle errors gracefully:

```ruby
result = swarm.execute("Task")

if result.success?
  puts result.content
else
  error = result.error

  case error
  when SwarmSDK::ConfigurationError
    puts "Configuration error: #{error.message}"
    # Fix config and retry

  when SwarmSDK::ToolExecutionError
    puts "Tool execution error: #{error.message}"
    # Check permissions or tool configuration

  when SwarmSDK::LLMError
    puts "LLM API error: #{error.message}"
    # Check API key, connectivity

  else
    puts "Unexpected error: #{error.message}"
    puts error.backtrace
  end
end
```

**Error recovery strategies**:

1. **Retry with backoff**:
```ruby
def execute_with_retry(swarm, prompt, max_attempts: 3)
  attempts = 0

  loop do
    attempts += 1
    result = swarm.execute(prompt)

    return result if result.success?

    if attempts >= max_attempts
      puts "Failed after #{attempts} attempts"
      return result
    end

    puts "Attempt #{attempts} failed, retrying..."
    sleep(2 ** attempts)  # Exponential backoff
  end
end
```

2. **Fallback to simpler agent**:
```ruby
result = swarm.execute("Complex task")

# Check error message for context-related issues
if !result.success? && result.error.message.include?("context")
  puts "Context limit reached, trying simpler agent"
  result = simple_swarm.execute("Simplified task")
end
```

3. **Hook-based recovery**:
```ruby
all_agents do
  hook :agent_stop do |ctx|
    if ctx.metadata[:finish_reason] == "max_tokens"
      SwarmSDK::Hooks::Result.reprompt("Continue your response")
    end
  end
end
```

### 7.4 Validation and Warnings

SwarmSDK validates configurations and emits warnings:

```ruby
swarm = SwarmSDK.load_file("config.yml")

# Check for warnings
warnings = swarm.validate

warnings.each do |warning|
  case warning[:type]
  when :model_not_found
    puts "⚠️  Agent '#{warning[:agent]}' uses unknown model '#{warning[:model]}'"
    puts "   Suggestions: #{warning[:suggestions].map { |s| s[:id] }.join(", ")}"
  end
end
```

**Warnings are non-fatal**: Swarm still executes, but you're informed of potential issues.

**Common warnings**:
- Model not in registry (typo or new model)
- Context tracking unavailable
- Missing API keys

### 7.5 Document Conversion

SwarmSDK can read and convert documents:

**PDF files**:
```ruby
agent :pdf_reader do
  description "PDF analyst"
  model "gpt-4"
  system_prompt "Analyze PDF documents"
  # Read tool includes PDF support
end
```

**Agent usage**:
```
Read(file_path: "report.pdf")
# Returns text content extracted from PDF
```

**DOCX files**:
```
Read(file_path: "document.docx")
# Returns text content from Word document
```

**XLSX files**:
```
Read(file_path: "data.xlsx")
# Returns CSV representation of spreadsheet
```

**Image support**:
```
Read(file_path: "diagram.png")
# For models with vision capabilities
```

**Use cases**:
- Document analysis
- Data extraction from PDFs
- Report generation
- Contract review

---

## Part 8: Best Practices

### 8.1 When to Use Single Agent vs Multi-Agent

**Use single agent when**:
- Task is simple and focused
- One expertise domain
- Speed matters (less delegation overhead)
- Budget is tight (fewer LLM calls)

**Example - Single agent**:
```ruby
swarm = SwarmSDK.build do
  name "Simple Helper"
  lead :assistant

  agent :assistant do
    description "General helper"
    model "gpt-4"
    system_prompt "Answer questions and help with tasks"
  end
end
```

**Use multi-agent when**:
- Task requires multiple expertise areas
- Quality matters more than speed
- Different stages need different approaches
- Task benefits from review/validation

**Example - Multi-agent**:
```ruby
swarm = SwarmSDK.build do
  name "Code Quality Team"
  lead :developer

  agent :developer do
    description "Writes code"
    model "gpt-4"
    system_prompt "Write clean, well-tested code"
    tools :Write, :Edit
    delegates_to :reviewer, :security_checker
  end

  agent :reviewer do
    description "Reviews code quality"
    model "claude-sonnet-4"
    system_prompt "Check for bugs and improvements"
  end

  agent :security_checker do
    description "Security audit"
    model "claude-opus-4"
    system_prompt "Find security vulnerabilities"
  end
end
```

### 8.2 Organizing Large Swarms

**Strategy 1: Functional Teams**
```
Lead (Coordinator)
├── Development Team
│   ├── Backend Dev
│   ├── Frontend Dev
│   └── Database Specialist
├── Quality Team
│   ├── Tester
│   └── Security Auditor
└── Documentation Team
    └── Technical Writer
```

**Strategy 2: Layered Architecture**
```
Executive Layer → Strategic decisions
Coordination Layer → Task breakdown and planning
Execution Layer → Implementation
Validation Layer → Testing and review
```

**Strategy 3: Node-Based Pipeline**
```
Requirements → Design → Implementation → Testing → Deployment
    (PM)       (Arch)    (Dev team)      (QA)      (DevOps)
```

**Configuration structure**:
```
project/
├── swarm.yml                    # Main swarm config
├── agents/                      # Agent definitions
│   ├── backend.md
│   ├── frontend.md
│   └── qa.md
├── scripts/                     # Hook scripts
│   ├── validate.sh
│   └── notify.sh
└── .env                        # API keys
```

### 8.3 Testing Strategies

**Unit test agents**:
```ruby
RSpec.describe "Backend Agent" do
  let(:swarm) do
    SwarmSDK.build do
      name "Test Swarm"
      lead :backend

      agent :backend do
        description "Backend dev"
        model "gpt-4"
        system_prompt "Write Ruby code"
        tools :Write
      end
    end
  end

  it "creates files" do
    result = swarm.execute("Create a User class")

    expect(result.success?).to be true
    expect(File.exist?("user.rb")).to be true
  end
end
```

**Integration test workflows**:
```ruby
RSpec.describe "Development Pipeline" do
  let(:swarm) { SwarmSDK.load_file("swarm.yml") }

  it "completes full workflow" do
    result = swarm.execute("Build auth system")

    expect(result.success?).to be true
    # agents_involved returns symbols, not strings
    expect(result.agents_involved).to include(:planner, :coder, :tester)
    expect(result.logs.count { |l| l[:type] == "tool_call" }).to be > 0
  end
end
```

**Test hooks**:
```ruby
it "blocks dangerous commands" do
  result = swarm.execute("Run rm -rf /")

  expect(result.success?).to be false
  expect(result.error.message).to include("blocked")
end
```

**Mock LLM responses** (for faster tests):
```ruby
# Use a test double or stub
allow(LLM).to receive(:chat).and_return(
  {content: "Test response", usage: {tokens: 100}}
)
```

### 8.4 Performance Optimization

**1. Choose appropriate models**:
```ruby
# Fast tasks
agent :quick do
  model "claude-haiku-4"  # Fastest, cheapest
end

# Balanced tasks
agent :balanced do
  model "gpt-4"  # Good balance
end

# Complex tasks
agent :complex do
  model "claude-opus-4"  # Best quality
end
```

**2. Use agent-less nodes**:
```ruby
# Pure computation, no LLM
node :data_transform do
  output do |ctx|
    JSON.parse(ctx.content).transform_values(&:upcase)
  end
end
```

**3. Parallelize independent work**:
```ruby
# These run in sequence but are independent
node :frontend do
  agent(:frontend_dev)
  depends_on :planning
end

node :backend do
  agent(:backend_dev)
  depends_on :planning  # Same dependency, parallel work
end
```

**4. Cache results in scratchpad**:
```ruby
agent :analyzer do
  description "Analyzer with caching"
  model "gpt-4"
  system_prompt "Check scratchpad before analyzing"

  hook :pre_tool_use, matcher: "ScratchpadRead" do |ctx|
    # Read cached result
    cached = ctx.tool_call.parameters[:file_path]
    puts "Using cached: #{cached}"
  end
end
```

**5. Limit context with transformers**:
```ruby
node :summarizer do
  agent(:analyst)
  depends_on :research

  input do |ctx|
    # Summarize long research output
    research = ctx.content
    research.lines.first(50).join("\n") + "\n\n[... truncated]"
  end
end
```

### 8.5 Security Considerations

**1. Restrict file access**:
```ruby
agent :sandboxed do
  description "Sandboxed agent"
  model "gpt-4"
  directory "/safe/sandbox"
  tools :Write, :Read

  permissions do
    tool(:Write).allow_paths "output/**"
    tool(:Write).deny_paths "**/*.sh", "**/.env"
  end
end
```

**2. Block dangerous commands**:
```ruby
agent :executor do
  description "Safe executor"
  model "gpt-4"
  tools :Bash

  permissions do
    tool(:Bash).allow_commands "ls", "pwd", "echo", "cat"
    tool(:Bash).deny_commands "rm", "dd", "sudo", "chmod", "curl"
  end
end
```

**3. Validate agent outputs**:
```ruby
all_agents do
  hook :post_tool_use, matcher: "Write" do |ctx|
    file = ctx.tool_call.parameters[:file_path]
    content = ctx.tool_call.parameters[:content]

    # Block suspicious patterns
    if content.include?("eval(") || content.include?("exec(")
      SwarmSDK::Hooks::Result.halt("Suspicious code pattern detected")
    end
  end
end
```

**4. Audit all operations**:
```ruby
all_agents do
  hook :post_tool_use do |ctx|
    File.open("audit.log", "a") do |f|
      f.puts "#{Time.now} | #{ctx.agent_name} | #{ctx.tool_call.name} | #{ctx.tool_call.parameters}"
    end
  end
end
```

**5. Use separate environments**:
```
Development: Full access, all tools
Staging: Restricted access, validated outputs
Production: Minimal access, extensive hooks
```

**6. Disable filesystem tools globally (system-wide security)**:
```ruby
# For multi-tenant platforms or sandboxed environments
SwarmSDK.configure do |config|
  config.allow_filesystem_tools = false
end

# Or via environment variable (recommended for production)
ENV['SWARM_SDK_ALLOW_FILESYSTEM_TOOLS'] = 'false'

# Agents can now only use non-filesystem tools
swarm = SwarmSDK.build do
  name "API Analyst"
  lead :analyst

  agent :analyst do
    description "Analyzes data via APIs only"
    model "gpt-5"
    # These work: Think, WebFetch, Clock, TodoWrite, Scratchpad*, Memory*
    tools :Think, :WebFetch
    # These are blocked: Read, Write, Edit, MultiEdit, Grep, Glob, Bash
  end
end

# Override per-swarm if needed
restricted_swarm = SwarmSDK.build(allow_filesystem_tools: false) do
  # ... specific swarm that needs extra restriction
end
```

**Use cases:**
- **Multi-tenant platforms**: Prevent user-provided swarms from accessing filesystem
- **Containerized deployments**: Read-only filesystems or restricted environments
- **Compliance requirements**: Data analysis workloads that forbid file operations
- **CI/CD pipelines**: Agents should only interact via APIs

**Key features:**
- **Security boundary**: Cannot be overridden by swarm YAML/DSL configuration
- **Validation**: Errors caught at build time with clear messages
- **Priority**: Explicit parameter > Global setting > Environment variable > Default (true)
- **Non-breaking**: Defaults to `true` for backward compatibility

### 8.6 Cost Management

**Track costs in real-time**:
```ruby
max_cost = 1.00  # $1 limit
current_cost = 0.0

swarm.execute("Task") do |log|
  if log[:usage]
    current_cost += log[:usage][:cost]

    if current_cost > max_cost
      puts "Cost limit reached: $#{current_cost}"
      # Stop execution
    end
  end
end
```

**Use cost hooks**:
```ruby
all_agents do
  hook :agent_step do |ctx|
    cost = ctx.metadata[:usage][:cost]

    if cost > 0.10  # 10 cents per response
      SwarmSDK::Hooks::Result.finish_agent("Cost threshold exceeded")
    end
  end
end
```

**Budget per stage**:
```ruby
node :expensive_stage do
  agent(:analyst)

  hook :agent_step do |ctx|
    if ctx.metadata[:usage][:cost] > 0.50
      SwarmSDK::Hooks::Result.finish_agent("Stage budget exceeded")
    end
  end
end
```

**Cost optimization checklist**:
- [ ] Use smaller models for simple tasks
- [ ] Set max_tokens limits
- [ ] Lower temperature (fewer tokens)
- [ ] Use agent-less nodes for computation
- [ ] Cache results in scratchpad
- [ ] Batch similar operations
- [ ] Monitor and set cost alerts

### 8.7 Monitoring and Observability

**Structured logging to files**:
```ruby
log_file = File.open("swarm.log", "a")

swarm.execute("Task") do |log|
  log_file.puts JSON.generate(log)
end

log_file.close
```

**Send to external service**:
```ruby
swarm.execute("Task") do |log|
  case log[:type]
  when "agent_stop"
    metrics.track("agent.completion", {
      agent: log[:agent],
      duration: log[:usage][:duration],
      tokens: log[:usage][:total_tokens],
      cost: log[:usage][:cost]
    })

  when "tool_call"
    metrics.increment("tool.#{log[:tool]}.calls")
  end
end
```

**Dashboard metrics**:
```ruby
# Collect over time
{
  total_executions: 1234,
  success_rate: 0.95,
  avg_duration: 45.2,
  total_cost: 123.45,
  agent_usage: {
    backend: 450,
    frontend: 380,
    qa: 200
  },
  tool_usage: {
    Write: 890,
    Read: 1200,
    Bash: 340
  }
}
```

### 8.8 Common Patterns Summary

**Pattern: Code Review Workflow**
```
Developer → Reviewer → Developer (iterate) → Final approval
```

**Pattern: Research and Implementation**
```
Researcher (gathers info) → Analyst (processes) → Writer (creates)
```

**Pattern: Multi-Stage Pipeline**
```
Plan → Design → Implement → Test → Deploy
```

**Pattern: Specialist Pool**
```
Lead delegates to: Backend, Frontend, Database, Security, DevOps (as needed)
```

**Pattern: Peer Collaboration**
```
Backend ↔ Frontend (coordinate), both → QA (validate)
```

**Pattern: Hierarchical Teams**
```
Manager
  ├── Team Lead (Backend)
  │     ├── Senior Dev
  │     └── Junior Dev
  └── Team Lead (Frontend)
        ├── UI Dev
        └── UX Designer
```

---

## Summary

You've now learned **100% of SwarmSDK features**:

✅ **Part 1: Fundamentals** - Agents, models, providers, directories, system prompts, coding_agent flag

✅ **Part 2: Tools and Permissions** - All built-in tools, path/command permissions, bypass, scratchpad

✅ **Part 3: Agent Collaboration** - Delegation patterns, multi-level teams, markdown agents, delegation tracking

✅ **Part 4: Hooks System** - All 13 hook events, 6 hook actions, Ruby blocks, shell commands, breakpoints

✅ **Part 5: Node Workflows** - Multi-stage pipelines, dependencies, input/output transformers (Ruby + Bash), agent-less nodes, NodeContext API

✅ **Part 6: Advanced Configuration** - MCP integration (stdio/SSE/HTTP), custom providers, context management, rate limiting, timeout, LLM parameters, Responses API

✅ **Part 7: Production Features** - Structured logging, token/cost tracking, error handling, validation, document conversion

✅ **Part 8: Best Practices** - Architecture patterns, testing strategies, performance optimization, security, cost management, monitoring

## Next Steps

**Master specific features**:
- [Node Workflows Guide](node-workflows-guide.md) - Deep dive into pipelines
- [Hooks API Reference](hooks-api.md) - Complete hooks documentation
- [Permissions Guide](permissions.md) - Security and access control
- [Performance Tuning](performance-tuning.md) - Optimization techniques

**Real-world examples**:
- [Use Cases](use-cases/) - Practical swarm examples
- [Code Review Swarm](use-cases/code-review.md)
- [Documentation Generator](use-cases/documentation-generation.md)
- [Data Analysis Pipeline](use-cases/data-analysis.md)

**API Reference**:
- [SwarmSDK API](../../api/swarm-sdk.md)
- [Agent Configuration](../../api/agent-configuration.md)
- [Tools API](../../api/tools.md)
- [Hooks API](../../api/hooks.md)

## Where to Get Help

- **Documentation**: [SwarmSDK Guides](../README.md)
- **Examples**: [Example Swarms](../../../examples/v2/)
- **Issues**: [GitHub Issues](https://github.com/parruda/claude-swarm/issues)

---

**You now have complete knowledge of SwarmSDK.** Build amazing AI agent teams!
