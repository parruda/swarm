# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains three integrated Ruby gems that work together to create collaborative AI agent systems:

- **SwarmSDK** (`lib/swarm_sdk/`) - Core SDK for building multi-agent AI systems using RubyLLM
- **SwarmMemory** (`lib/swarm_memory/`) - Persistent memory system with semantic search for agents
- **SwarmCLI** (`lib/swarm_cli/`) - Modern command-line interface using TTY toolkit components

### SwarmSDK

SwarmSDK is a single-process, lightweight framework for building collaborative AI agent systems. Key features:

- **Single Process**: All agents run in the same Ruby process using RubyLLM
- **Agent Delegation**: Agents can delegate tasks to specialized agents
- **Tool System**: Rich set of built-in tools (Read, Write, Edit, Bash, etc.)
- **Ruby DSL**: Clean, intuitive API for defining agent swarms
- **Event System**: Comprehensive event emission for monitoring and debugging
- **State Management**: Snapshot/restore for session persistence
- **Async Support**: Built on Async gem for efficient concurrent execution
- **MCP Integration**: Connect to external MCP servers via RubyLLM::MCP

### SwarmMemory

SwarmMemory provides hierarchical persistent memory with semantic search capabilities:

- **Semantic Search**: Fast ONNX-based embeddings using Informers gem
- **Memory Tools**: MemoryWrite, MemoryRead, MemoryEdit, MemoryDelete, MemoryGrep, MemoryGlob
- **SDK Integration**: Seamlessly integrates with SwarmSDK through plugin system
- **Frontmatter Support**: Extract metadata from memory entries
- **Storage Abstraction**: Pluggable storage backends
- **Defragmentation**: Optimize memory storage over time

### SwarmCLI

SwarmCLI provides a modern, user-friendly command-line interface:

- **Dual-Mode Support**: Interactive REPL and non-interactive automation
- **TTY Toolkit**: Rich terminal UI with Pastel styling, TTY::Spinner, TTY::Markdown
- **JSON Logging**: Structured logs for automation and scripting
- **Reline Integration**: Advanced line editing with history and completion
- **Configuration Management**: YAML-based swarm definitions
- **Memory Commands**: Full memory system integration (if swarm_memory installed)

## Development Commands

### Testing
NEVER RUN ALL TESTS WITH `bundle exec rake test`. Run tests for each component separately.

Each component has its own test suite:

```bash
# Run specific component tests
bundle exec rake swarm_sdk:test      # SwarmSDK tests
bundle exec rake swarm_memory:test   # SwarmMemory tests
bundle exec rake swarm_cli:test      # SwarmCLI tests
```

**Important**: Tests should not generate any output to stdout or stderr. When writing tests:
- Capture or suppress all stdout/stderr output from tested methods
- Use `capture_io` or `capture_subprocess_io` for Minitest
- Redirect output streams to `StringIO` or `/dev/null` when necessary
- Mock or stub methods that produce console output
- Ensure clean test output for better CI/CD integration

Example:
```ruby
def test_command_with_output
  output, err = capture_io do
    # Code that produces output
  end
  # Test assertions here
end
```

### Linting

```bash
bundle exec rubocop -A       # Run RuboCop linter to auto fix problems
```

## Architecture

### SwarmSDK Architecture (`lib/swarm_sdk/`)

**Core Components:**

- **Swarm** - Main orchestrator managing multiple agents with shared rate limiting
- **Agent::Definition** - Agent configuration and validation
- **Agent::Chat** - RubyLLM chat wrapper with tool execution and delegation
- **AgentInitializer** - Complex 5-pass agent setup with tool and MCP configuration
- **ToolConfigurator** - Tool creation, permissions, and delegation tool generation
- **McpConfigurator** - MCP client management and configuration
- **NodeOrchestrator** - Multi-node workflow execution with dependencies

**Key Subsystems:**

- **Events**: LogStream + LogCollector for comprehensive event emission
- **Hooks**: Pre/post tool execution, swarm lifecycle hooks
- **State**: Snapshot/restore for session persistence
- **Tools**: 25+ built-in tools (Read, Write, Edit, Bash, Grep, Glob, etc.)
- **Plugins**: Extensible plugin system (SwarmMemory integrates via plugins)

**User-Facing APIs:**

```ruby
# Ruby DSL (Recommended)
swarm = SwarmSDK.build do
  name "Development Team"
  lead :backend

  agent :backend do
    model "claude-sonnet-4"
    description "Backend developer"
    prompt "You build APIs and databases"
    tools :Read, :Edit, :Bash
    delegates_to :database
  end
end

result = swarm.execute("Build authentication system")

# YAML String API
yaml = File.read("swarm.yml")
swarm = SwarmSDK.load(yaml, base_dir: "/path/to/project")

# YAML File API (Convenience)
swarm = SwarmSDK.load_file("swarm.yml")
```

### SwarmMemory Architecture (`lib/swarm_memory/`)

**Core Components:**

- **Core::Storage** - Hierarchical file-based storage with frontmatter
- **Core::Index** - FAISS-based semantic search index
- **Core::Embedder** - ONNX embeddings via Informers gem
- **Tools::Memory*** - Memory manipulation tools (Write, Read, Edit, Delete, etc.)
- **Integration::SDKPlugin** - SwarmSDK plugin for seamless integration

**Memory Tools:**

- **MemoryWrite** - Create/update memory entries with semantic indexing
- **MemoryRead** - Retrieve memory entries with optional semantic search
- **MemoryEdit** - Edit specific memory entries
- **MemoryMultiEdit** - Batch edit multiple entries
- **MemoryDelete** - Remove memory entries
- **MemoryGrep** - Search memory content with regex
- **MemoryGlob** - Find memory entries by pattern
- **MemoryDefrag** - Optimize storage and rebuild indices

**Integration:**

```ruby
# Enable memory for an agent
SwarmSDK.build do
  agent :researcher do
    model "claude-sonnet-4"
    memory do
      directory("tmp/memory/corpus")
      mode(:researcher)
    end
  end
end
```

### SwarmCLI Architecture (`lib/swarm_cli/`)

**Core Components:**

- **Commands::Run** - Main command for executing swarms
- **InteractiveREPL** - Interactive mode with Reline
- **UI::EventRenderer** - Event formatting and display
- **UI::Formatters** - TTY-based output formatting
- **ConfigLoader** - YAML configuration parsing

**Key Features:**

- **Non-Interactive Mode**: JSON structured logs for automation
- **Interactive Mode**: Rich terminal UI with colors, spinners, trees
- **Event Streaming**: Real-time display of agent actions
- **Configuration**: YAML-based swarm definitions
- **Reline Integration**: Advanced input editing with history

## Code Separation

**CRITICAL**: The three components are completely separate:

- **SwarmSDK**: Core SDK functionality in `lib/swarm_sdk/` and `lib/swarm_sdk.rb`
- **SwarmMemory**: Memory system in `lib/swarm_memory/` and `lib/swarm_memory.rb`
- **SwarmCLI**: CLI interface in `lib/swarm_cli/` and `lib/swarm_cli.rb`

**NEVER mix SDK, Memory, and CLI code** - they are separate gems with distinct concerns:
- SDK provides the programmatic API
- Memory provides persistent storage with semantic search
- CLI provides the command-line interface

## Testing Guidelines

### Component-Specific Tests

- **SwarmSDK**: `test/swarm_sdk/**/*_test.rb`
- **SwarmMemory**: `test/swarm_memory/**/*_test.rb`
- **SwarmCLI**: `test/swarm_cli/**/*_test.rb`

### Best Practices

1. **Isolation**: Each component's tests should not depend on others
2. **Mocking**: Mock external dependencies (LLM API calls, file system, etc.)
3. **Cleanup**: Always clean up test artifacts (temp files, directories)
4. **No Output**: Tests should be silent (capture stdout/stderr)
5. **Fast**: Unit tests should be fast; integration tests can be slower

### Example Test Structure

```ruby
require "test_helper"

class SwarmSDK::MyFeatureTest < Minitest::Test
  def setup
    @swarm = SwarmSDK::Swarm.new(name: "Test Swarm")
  end

  def teardown
    @swarm.cleanup if @swarm
  end

  def test_feature_works
    # Suppress output
    _out, _err = capture_io do
      result = @swarm.execute("test prompt")
      assert result.success?
    end
  end
end
```

## Zeitwerk Autoloading

This project uses Zeitwerk for automatic class loading. Important guidelines:

### Require Statement Rules

1. **DO NOT include any require statements for lib files**: Zeitwerk automatically loads all classes. Never use `require`, `require_relative`, or `require "swarm_sdk/..."` for internal project files.

2. **All dependencies must be consolidated in the main file**:
   - `lib/swarm_sdk.rb` - SDK dependencies
   - `lib/swarm_memory.rb` - Memory dependencies
   - `lib/swarm_cli.rb` - CLI dependencies

3. **No requires in other lib files**: Individual files should not have any require statements. They rely on:
   - Dependencies loaded in the main file
   - Other classes autoloaded by Zeitwerk

### Example

```ruby
# ✅ CORRECT - lib/swarm_sdk.rb
require "async"
require "ruby_llm"
require "zeitwerk"
loader = Zeitwerk::Loader.new
loader.setup

# ❌ INCORRECT - lib/swarm_sdk/some_class.rb
require "async"  # Don't do this!
require_relative "other_class"  # Don't do this!
require "swarm_sdk/configuration"  # Don't do this!
```

## Development Guidelines

**Code Quality:**
- Write PROFESSIONAL, CLEAN, MAINTAINABLE, TESTABLE code
- NEVER mix SDK, Memory, and CLI code
- NEVER call private methods from outside a class
- NEVER use `send`, `instance_variable_get`, or `instance_variable_set`
- DO NOT create methods only for testing - write production testable code

**Architecture:**
- Keep concerns separated (SDK = API, Memory = Storage, CLI = Interface)
- Use dependency injection for testability
- Follow Ruby idioms and conventions
- Document public APIs with YARD comments

**Testing:**
- Write tests for new features
- Maintain test coverage
- Tests should be fast and isolated
- No stdout/stderr output in tests

## Ruby Documentation Standards

### YARD Documentation Requirements

All Ruby code MUST include comprehensive YARD documentation. Follow these rules:

#### Required for ALL Public Methods:
- `@param` for each parameter with type annotation
- `@return` with type annotation (use multiple if different return types possible)
- `@raise` for any exceptions that may be raised
- At least one `@example` showing typical usage
- `@note` for important behavioral details or side effects

#### Required for Complex Methods:
- `@option` for each hash option parameter
- Multiple `@example` blocks showing different use cases
- `@see` links to related methods
- Performance considerations if relevant

#### Method Documentation Template:
```ruby
# Brief one-line description
#
# Optional longer description explaining the method's purpose,
# important details, or context.
#
# @param name [Type] description
# @param options [Hash] optional parameters
# @option options [Type] :key description
#
# @return [Type] description of return value
# @raise [ExceptionType] when this exception occurs
#
# @example Basic usage
#   code_example
#
# @example Advanced usage
#   code_example
#
# @note Important behavioral detail
# @see #related_method
def method_name(name, options = {})
end
```

## Key Concepts

### SwarmSDK Concepts

**Agents**: AI agents with specific roles, tools, and capabilities
**Delegation**: Agents can delegate tasks to other specialized agents
**Tools**: Built-in and custom tools for agent capabilities
**Events**: Comprehensive logging and monitoring system
**Hooks**: Lifecycle hooks for pre/post tool execution
**State**: Snapshot/restore for session persistence

### SwarmMemory Concepts

**Memory Entries**: Markdown files with frontmatter metadata
**Semantic Search**: ONNX-based embeddings for similarity search
**Storage**: Hierarchical file-based storage
**Index**: FAISS index for fast nearest-neighbor search
**Tools**: Memory manipulation tools integrated with SDK

### SwarmCLI Concepts

**Interactive Mode**: REPL with rich terminal UI
**Non-Interactive Mode**: Automation-friendly JSON output
**Configuration**: YAML-based swarm definitions
**Event Rendering**: Real-time display of agent actions

## Dependencies

### SwarmSDK
- `async` (~> 2.0) - Concurrent execution
- `ruby_llm` (~> 1.9) - LLM interactions
- `ruby_llm-mcp` (~> 0.7) - MCP client support
- `zeitwerk` (~> 2.6) - Autoloading

### SwarmMemory
- `async` (~> 2.0) - Concurrent execution
- `informers` (~> 1.2.1) - ONNX embeddings for semantic search
- `rice` (~> 4.6.0) - Ruby C extension binding (for FAISS)
- `ruby_llm` (~> 1.9) - LLM interactions
- `swarm_sdk` (~> 2.2) - Core SDK integration
- `zeitwerk` (~> 2.6) - Autoloading

### SwarmCLI
- `fast-mcp` (~> 1.6) - MCP server support for CLI
- `pastel` - Terminal text styling and colors
- `swarm_sdk` (~> 2.2) - Core SDK
- `tty-box` - Drawing boxes and frames
- `tty-cursor` - Terminal cursor control
- `tty-link` - Hyperlink support
- `tty-markdown` - Markdown rendering
- `tty-option` - Command-line option parsing
- `tty-spinner` - Progress indicators
- `tty-tree` - Tree structure rendering
- `zeitwerk` - Autoloading
- `reline` - Line editing (Ruby stdlib, no gem dependency)

**Document parsing tools (for Read tool):**
- `csv` - CSV file parsing
- `docx` (~> 0.10) - Word document parsing
- `pdf-reader` (~> 2.15) - PDF parsing
- `reverse_markdown` (~> 3.0.0) - HTML to Markdown conversion
- `roo` (~> 3.0.0) - Spreadsheet parsing (xlsx, xlsm, ods)

## Additional Resources

- **SwarmSDK Documentation**: See `docs/v2/` for comprehensive guides
- **SwarmMemory Documentation**: See `docs/memory/` for memory system details
- **SwarmCLI Documentation**: See `docs/cli/` for CLI usage and configuration
- **RubyLLM Documentation**: ~/src/github.com/crmne/ruby_llm
- **Async Documentation**: ~/src/github.com/socketry/async

## Notes for Claude Code

When working with this codebase:

1. **Always check which component** you're working with (SDK, Memory, or CLI)
2. **Never cross boundaries** between components unless through public APIs
3. **Run component-specific tests** after making changes
4. **Follow Zeitwerk rules** - no require statements in lib files
5. **Maintain code quality** - professional, clean, testable code
6. **Suppress test output** - use capture_io for silent tests
7. **Document public APIs** - use YARD comments for public methods

This is an open-source project - code should be exemplary and well-documented.

When making plans, do not include time-based effort estimates.