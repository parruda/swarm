# Changelog

All notable changes to SwarmSDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking Changes

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
  - **`SwarmSDK.settings.allow_filesystem_tools`** - Global setting to enable/disable filesystem tools (default: true)
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
