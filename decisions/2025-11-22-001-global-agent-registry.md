# Decision: Global Agent Registry for SwarmSDK

**Date:** 2025-11-22
**Status:** Implemented

## Context

Users wanted the ability to declare agents in separate files and reference them by name in swarm definitions. This promotes:
- Code reuse across multiple swarms
- Separation of concerns (agent definitions vs swarm composition)
- Cleaner organization for large projects

## Decision

Implement a global `AgentRegistry` that stores agent configuration blocks and allows referencing them in `SwarmSDK.build` and `SwarmSDK.workflow` definitions.

### API Design

```ruby
# Register agent in separate file (e.g., agents/backend.rb)
SwarmSDK.agent :backend do
  model "claude-sonnet-4"
  description "Backend developer"
  system_prompt "You build APIs"
  tools :Read, :Edit, :Bash
end

# Reference in swarm definition
SwarmSDK.build do
  name "Dev Team"
  lead :backend

  agent :backend  # Lookup from registry
end

# Extend with overrides
SwarmSDK.build do
  name "Extended Team"
  lead :backend

  agent :backend do
    tools :CustomTool  # Adds to registry tools
  end
end
```

### Key Design Decisions

1. **Proc Storage (not Lambda)**
   - Procs work naturally with `instance_eval` DSL semantics
   - Flexible arity handling suits DSL blocks
   - Blocks passed to methods are already Procs

2. **Class with Class Methods (not Singleton)**
   - Simpler than full Singleton pattern
   - Easier to test with `AgentRegistry.clear`
   - Class methods feel natural for global registry

3. **Duplicate Registration Error**
   - Raises `ArgumentError` if registering same name twice
   - Prevents accidental overwrites across files
   - User must call `SwarmSDK.clear_agent_registry!` to reset

4. **Registry Takes Precedence**
   - When `agent :name do ... end` is called and agent is registered:
     - Registry config is applied first
     - Block becomes overrides (additive)
   - Promotes DRY principle - registry is source of truth

5. **No Thread Safety**
   - SwarmSDK uses fiber-based concurrency (Async gem)
   - Single-threaded execution means no race conditions
   - Documented limitation for multi-threaded environments

6. **Delegation is Swarm-Specific (Best Practice)**
   - Don't set `delegates_to` in registry agent definitions
   - Delegation targets depend on which agents exist in each swarm
   - Set `delegates_to` as an override when referencing the agent in a swarm
   - This makes agents truly reusable across different swarm compositions

## Implementation

### New Files
- `lib/swarm_sdk/agent_registry.rb` - AgentRegistry class

### Modified Files
- `lib/swarm_sdk.rb` - Added `SwarmSDK.agent` and `SwarmSDK.clear_agent_registry!`
- `lib/swarm_sdk/builders/base_builder.rb` - Added registry lookup to `#agent` method

### Test Coverage
- 26 tests covering:
  - Registry class methods (register, get, registered?, names, clear)
  - Module methods (agent, clear_agent_registry!)
  - Registry lookup in Swarm and Workflow builders
  - Registry + overrides behavior
  - Multiple swarms sharing registry
  - Error handling
  - Edge cases

## Alternatives Considered

1. **Explicit Syntax (`agent :name, from: :registry`)**
   - Rejected: Too verbose for common use case
   - Current behavior is intuitive (no args = lookup)

2. **Warning on Shadow**
   - Rejected: Too noisy, users might ignore
   - Error-free operation preferred

3. **Thread-Safe Implementation**
   - Rejected: Unnecessary complexity for fiber-based model
   - The definitions should be eager loaded in the app that is using the SDK
   - Documented limitation acceptable

## Enhancement: Workflow Node Registry Fallback

Added automatic agent resolution in workflow nodes. When `agent(:name)` is called inside a node:

1. First checks if agent is defined at workflow level
2. If not found, checks the global AgentRegistry
3. If still not found, raises ConfigurationError

This allows powerful patterns like:

```ruby
# agents/shared.rb
SwarmSDK.agent :shared_analyzer do
  model "claude-sonnet-4"
  description "Shared analyzer"
end

# workflow.rb
SwarmSDK.workflow do
  name "Pipeline"
  start_node :analyze

  # No need to define shared_analyzer here!

  node :analyze do
    agent(:shared_analyzer)  # Auto-resolved from registry
  end
end
```

The fallback also resolves delegation targets:

```ruby
node :process do
  agent(:main_agent).delegates_to(:helper_agent)
  # Both resolved from registry
end
```

### Implementation
- Modified `Workflow::Builder#build_workflow` to call `resolve_missing_agents_from_registry`
- Added `collect_referenced_agents` to gather all agents from nodes (including delegates_to)
- Resolution happens at build time before agent definitions are built

## Consequences

### Positive
- Clean separation of agent definitions from swarm composition
- Easy code reuse across swarms
- Intuitive API that matches existing DSL patterns
- Works with both Swarm and Workflow builders
- Workflow nodes automatically resolve agents from registry
- Delegation targets also auto-resolve from registry

### Negative
- Global state (mitigated by clear method for testing)
- Not thread-safe (documented limitation)
- Must require agent files before building swarms
