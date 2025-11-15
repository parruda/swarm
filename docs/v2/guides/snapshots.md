# Snapshot & Restore Guide

Enable multi-turn conversations across process restarts with SwarmSDK's snapshot/restore functionality.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Reconstructing Snapshots from Events](#reconstructing-snapshots-from-events)
- [API Reference](#api-reference)
- [Use Cases](#use-cases)
- [Advanced Topics](#advanced-topics)
- [Troubleshooting](#troubleshooting)

## Overview

Snapshots capture your swarm's **conversation state** so you can pause work and resume later in a new process. This enables:

- **Multi-turn conversations** across process restarts
- **Session persistence** in web applications
- **Checkpoint/rollback** during long-running tasks
- **State inspection** and debugging

### What Gets Snapshotted

✅ **Included in Snapshots:**
- Agent conversation history (all messages)
- Agent context state (warnings, compression, TodoWrite tracking)
- Delegation instance conversations
- Scratchpad contents (volatile shared storage)
- Read tracking with content verification (prevents stale edits)
- Memory read tracking with content verification

❌ **NOT Included (stays in your config):**
- Agent definitions (model, tools, prompts)
- MCP server configurations
- SwarmMemory persistent storage (stays on disk)
- Hook configurations

## Quick Start

### Basic Workflow

```ruby
# 1. Create swarm and do work
swarm = SwarmSDK.build do
  name "Dev Team"
  lead :backend

  agent :backend do
    model "claude-sonnet-4"
    system_prompt "You build robust APIs"
    tools :Read, :Write, :Bash
  end
end

result = swarm.execute("Build authentication system")

# 2. Create snapshot
snapshot = swarm.snapshot

# 3. Save to file
snapshot.write_to_file("session.json")

# === Process ends, new process starts ===

# 4. Load snapshot
snapshot = SwarmSDK::Snapshot.from_file("session.json")

# 5. Recreate swarm (SAME config as before)
swarm = SwarmSDK.build do
  name "Dev Team"
  lead :backend

  agent :backend do
    model "claude-sonnet-4"
    system_prompt "You build robust APIs"
    tools :Read, :Write, :Bash
  end
end

# 6. Restore state
result = swarm.restore(snapshot)

if result.success?
  puts "✅ All agents restored"
else
  puts "⚠️ #{result.summary}"
end

# 7. Continue working with full context
swarm.execute("Add password reset functionality")
```

## Core Concepts

### Snapshot Object

The `Snapshot` class encapsulates snapshot data with convenient methods:

```ruby
snapshot = swarm.snapshot

# Convert to different formats
hash = snapshot.to_hash
json_string = snapshot.to_json
pretty_json = snapshot.to_json(pretty: true)

# Save to file
snapshot.write_to_file("session.json")
snapshot.write_to_file("session.json", pretty: false)

# Access metadata
snapshot.version: 2.0.0"
snapshot.type                 # => "swarm" or "workflow"
snapshot.snapshot_at          # => "2025-01-03T14:30:00Z"
snapshot.swarm_sdk_version    # => "2.1.3"
snapshot.agent_names          # => ["backend", "database"]
snapshot.delegation_instance_names  # => ["database@backend"]

# Type checks
snapshot.swarm?               # => true
snapshot.workflow?   # => false
```

### Loading Snapshots

Three factory methods for different sources:

```ruby
# From file (most common)
snapshot = SwarmSDK::Snapshot.from_file("session.json")

# From JSON string
json_string = redis.get("session:#{user_id}")
snapshot = SwarmSDK::Snapshot.from_json(json_string)

# From hash
hash = { version: 2.0.0", type: "swarm", ... }
snapshot = SwarmSDK::Snapshot.from_hash(hash)
```

### Configuration vs State

**Critical Concept**: Snapshots separate configuration from state.

```ruby
# Configuration (YAML/DSL) = What agents can do
swarm = SwarmSDK.build do
  agent :backend do
    model "claude-sonnet-4"      # Config
    tools :Read, :Write, :Bash   # Config
    system_prompt "You build..."  # Config
  end
end

# Snapshot = What agents remember
snapshot = swarm.snapshot  # Only conversation history

# You MUST recreate with same config when restoring
swarm2 = SwarmSDK.build do
  agent :backend do
    model "claude-sonnet-4"      # Must match original
    tools :Read, :Write, :Bash   # Must match original
    system_prompt "You build..."  # Must match original
  end
end

swarm2.restore(snapshot)  # Restores conversation only
```

### System Prompt Handling

**By default, system prompts come from your current configuration**, not from the snapshot. This means you can update system prompts without creating new sessions.

```ruby
# Original execution with system prompt A
swarm = SwarmSDK.build do
  agent :backend do
    system_prompt "You build robust APIs"  # System prompt A
  end
end
result = swarm.execute("Build auth")
snapshot = swarm.snapshot

# === Update system prompt in config ===

# Restoration with system prompt B (default behavior)
swarm = SwarmSDK.build do
  agent :backend do
    system_prompt "You build secure APIs with comprehensive logging"  # System prompt B (NEW!)
  end
end
swarm.restore(snapshot)  # Uses NEW system prompt B with OLD conversation
swarm.execute("Add password reset")  # Continues with updated prompt
```

**Why This Design?**

System prompts define agent **behavior** and should come from configuration (your source of truth). Snapshots preserve **conversation history** (what happened), not configuration (how agents should behave).

This enables:
- ✅ Iterate on system prompts without losing conversation history
- ✅ A/B test different prompts on same conversation
- ✅ Update prompts across all sessions instantly
- ✅ Configuration stays in version control, conversations in storage

**System Prompts Include:**
- YAML `system_prompt` field
- SDK-injected defaults (environment, date, etc.)
- Plugin injections (SwarmMemory instructions, etc.)

When you restore, **all these injections apply**, giving you the complete current system prompt.

#### Historical System Prompts (Advanced)

For debugging, auditing, or exact reproducibility, use `preserve_system_prompts: true`:

```ruby
# Use historical system prompts from snapshot
swarm.restore(snapshot, preserve_system_prompts: true)
```

**Use Cases:**
- **Debugging**: "What system prompt was active when this bug occurred?"
- **Audit Trail**: "What instructions was the agent following at that time?"
- **Reproducibility**: "Run this exact scenario again with historical context"
- **Time-Travel Debugging**: "Replay with exact state from past execution"

**Example: Debugging with Historical Prompts**

```ruby
# Load snapshot from bug report
snapshot = SwarmSDK::Snapshot.from_file("bug_session.json")

# Restore with EXACT prompts that were active during bug
swarm = SwarmSDK.build { ... }
swarm.restore(snapshot, preserve_system_prompts: true)

# Now you can reproduce the exact behavior
result = swarm.execute("Trigger the bug scenario")
```

**Default vs Preserve Comparison:**

| Aspect | Default (`false`) | Preserve (`true`) |
|--------|------------------|-------------------|
| System Prompt Source | Current YAML config | Historical snapshot |
| SDK Injections | Current defaults | Historical defaults |
| Plugin Injections | Current plugins | Historical plugins |
| Use Case | Production, iteration | Debugging, audit |
| Config Changes | Apply immediately | Ignored |

## Reconstructing Snapshots from Events

SwarmSDK can reconstruct complete snapshots from event logs, enabling event sourcing and session persistence without explicit snapshot storage.

### Why Reconstruct from Events?

**Benefits:**
- ✅ **Single source of truth** - Events are the authoritative record
- ✅ **Complete audit trail** - Every state change is logged
- ✅ **Time travel** - Reconstruct state at any point in time
- ✅ **Event sourcing** - Store only events, derive snapshots on-demand
- ✅ **Smaller storage** - Events are append-only and compressible

**Use Cases:**
- Session persistence in databases
- Multi-process session sharing
- Debugging and replay
- Compliance and audit trails

### Basic Usage

```ruby
# 1. Collect events during execution
events = []
swarm = SwarmSDK::Swarm.from_config("swarm.yml")

result = swarm.execute("Build feature") do |event|
  events << event
end

# 2. Save events to storage (DB, file, Redis, etc.)
File.write("session_events.json", JSON.generate(events))

# === Later, even in a different process ===

# 3. Load events
events = JSON.parse(File.read("session_events.json"), symbolize_names: true)

# 4. Reconstruct snapshot from events
snapshot = SwarmSDK::SnapshotFromEvents.reconstruct(events)

# 5. Restore swarm from reconstructed snapshot
swarm = SwarmSDK::Swarm.from_config("swarm.yml")
swarm.restore(snapshot)

# 6. Continue with full context
swarm.execute("Continue feature development")
```

### What Gets Reconstructed

SnapshotFromEvents reconstructs **100% of swarm state**:

| Component | Source |
|-----------|--------|
| Swarm metadata | swarm_id, parent_swarm_id from all events |
| Agent conversations | user_prompt, agent_step, agent_stop, tool_result events |
| Delegation instances | Same events, agent name contains `@` |
| Context warnings | context_threshold_hit events |
| Compression state | compression_completed events |
| TodoWrite tracking | TodoWrite tool_call events |
| Active skills | LoadSkill tool_call arguments |
| Scratchpad contents | ScratchpadWrite tool_call arguments |
| Read tracking | Read tool_result metadata.read_digest |
| Memory tracking | MemoryRead tool_result metadata.read_digest |

### Event Requirements

Events must have:
- `:timestamp` - ISO 8601 format (auto-added by SwarmSDK)
- `:agent` - Agent identifier
- `:type` - Event type (user_prompt, agent_step, tool_call, etc.)

All SwarmSDK events automatically include these fields.

### Database Storage Pattern

```ruby
# ActiveRecord model
class SwarmEvent < ApplicationRecord
  # Schema: session_id:string, event_data:jsonb, timestamp:datetime

  scope :for_session, ->(session_id) { where(session_id: session_id).order(:timestamp) }
end

class SwarmSession
  def initialize(session_id)
    @session_id = session_id
  end

  # Execute and store events
  def execute(prompt, swarm_config)
    swarm = SwarmSDK::Swarm.from_config(swarm_config)

    # Restore from previous events if any exist
    previous_events = SwarmEvent.for_session(@session_id).pluck(:event_data)
    if previous_events.any?
      snapshot = SwarmSDK::SnapshotFromEvents.reconstruct(previous_events)
      swarm.restore(snapshot)
    end

    # Execute with event collection
    result = swarm.execute(prompt) do |event|
      SwarmEvent.create!(
        session_id: @session_id,
        event_data: event,
        timestamp: Time.parse(event[:timestamp])
      )
    end

    result
  end
end

# Usage
session = SwarmSession.new("user_123_session_456")
result = session.execute("Build authentication", "swarm.yml")
# All events saved to database, can reconstruct later
```

### Redis Streaming Pattern

```ruby
class RedisEventSession
  def initialize(redis, session_id)
    @redis = redis
    @session_id = session_id
    @events_key = "session:#{session_id}:events"
  end

  def execute(prompt, swarm_config)
    swarm = SwarmSDK::Swarm.from_config(swarm_config)

    # Restore from events
    restore_from_events(swarm)

    # Execute and stream events
    result = swarm.execute(prompt) do |event|
      @redis.rpush(@events_key, JSON.generate(event))
      @redis.expire(@events_key, 3600) # 1 hour TTL
    end

    result
  end

  def restore_from_events(swarm)
    events_json = @redis.lrange(@events_key, 0, -1)
    return if events_json.empty?

    events = events_json.map { |json| JSON.parse(json, symbolize_names: true) }
    snapshot = SwarmSDK::SnapshotFromEvents.reconstruct(events)
    swarm.restore(snapshot)
  end
end

# Usage
session = RedisEventSession.new(redis, "session_123")
result = session.execute("Build feature", "swarm.yml")
```

### Time Travel Debugging

```ruby
# Reconstruct state at any point in time
def reconstruct_at_time(events, timestamp)
  # Filter events up to specific timestamp
  events_until = events.select do |e|
    Time.parse(e[:timestamp]) <= Time.parse(timestamp)
  end

  # Reconstruct snapshot
  SwarmSDK::SnapshotFromEvents.reconstruct(events_until)
end

# Usage
all_events = load_all_events(session_id)

# See state at 3:00 PM
snapshot_3pm = reconstruct_at_time(all_events, "2025-11-04T15:00:00Z")
swarm = SwarmSDK::Swarm.from_config("swarm.yml")
swarm.restore(snapshot_3pm)
# Swarm state is exactly as it was at 3:00 PM

# See state at 4:00 PM
snapshot_4pm = reconstruct_at_time(all_events, "2025-11-04T16:00:00Z")

# Compare states
puts "Scratchpad changes:"
diff_scratchpad(snapshot_3pm[:scratchpad], snapshot_4pm[:scratchpad])
```

### Event Sourcing Architecture

```ruby
class EventSourcedSwarmSession
  def initialize(event_store, session_id)
    @event_store = event_store
    @session_id = session_id
  end

  # Execute and append events
  def execute(prompt, swarm_config)
    swarm = build_swarm(swarm_config)

    # Restore from all previous events
    restore_from_events(swarm)

    # Execute and store events
    result = swarm.execute(prompt) do |event|
      @event_store.append(@session_id, event)
    end

    result
  end

  # Reconstruct current state from events
  def current_snapshot
    events = @event_store.get_all(@session_id)
    SwarmSDK::SnapshotFromEvents.reconstruct(events)
  end

  private

  def restore_from_events(swarm)
    events = @event_store.get_all(@session_id)
    return if events.empty?

    snapshot = SwarmSDK::SnapshotFromEvents.reconstruct(events)
    swarm.restore(snapshot)
  end

  def build_swarm(config)
    SwarmSDK::Swarm.from_config(config)
  end
end

# Event store implementation
class PostgresEventStore
  def append(session_id, event)
    DB[:swarm_events].insert(
      session_id: session_id,
      event_type: event[:type],
      event_data: Sequel.pg_jsonb(event),
      timestamp: Time.parse(event[:timestamp])
    )
  end

  def get_all(session_id)
    DB[:swarm_events]
      .where(session_id: session_id)
      .order(:timestamp)
      .select_map(:event_data)
  end
end
```

### Hybrid Approach: Snapshots + Delta Events

For optimal performance with large sessions:

```ruby
class HybridSessionStorage
  def initialize(storage)
    @storage = storage
  end

  def save_session(session_id, swarm, events)
    # Save periodic snapshot every 100 events
    if events.size % 100 == 0
      snapshot = swarm.snapshot
      @storage.save_snapshot(session_id, snapshot)
      @storage.clear_old_events(session_id) # Keep only delta
    end

    # Always save events
    @storage.save_events(session_id, events)
  end

  def restore_session(session_id, swarm)
    # Get last snapshot
    snapshot = @storage.load_snapshot(session_id)

    # Get delta events since snapshot
    delta_events = @storage.load_events_after(session_id, snapshot&.snapshot_at)

    if snapshot
      # Restore from snapshot
      swarm.restore(snapshot)

      # Apply delta events if any
      if delta_events.any?
        delta_snapshot = SwarmSDK::SnapshotFromEvents.reconstruct(delta_events)
        swarm.restore(delta_snapshot)
      end
    elsif delta_events.any?
      # No snapshot, reconstruct from all events
      full_snapshot = SwarmSDK::SnapshotFromEvents.reconstruct(delta_events)
      swarm.restore(full_snapshot)
    end
  end
end
```

### Performance Considerations

**Reconstruction Time:**
- 1,000 events: ~10-20ms
- 10,000 events: ~100-200ms
- 100,000 events: ~1-2 seconds

**Optimization Strategies:**
1. Periodic snapshots (every N events)
2. Event compaction (merge old events into snapshot)
3. Parallel processing for multiple agents
4. Index events by agent and type in database

**Storage Size:**
- Average event: ~500 bytes
- Average snapshot: ~10-50KB
- 1000 events ≈ 500KB vs 1 snapshot ≈ 30KB

### RestoreResult

The `restore()` method returns a `RestoreResult` with information about the restoration:

```ruby
result = swarm.restore(snapshot)

# Check if fully successful
if result.success?
  puts "All agents restored successfully"
end

# Check if partial restore (some agents skipped)
if result.partial_restore?
  puts result.summary
  # => "Snapshot restored with warnings. 1 agents skipped, 0 delegation instances skipped."

  result.warnings.each do |warning|
    puts "⚠️ #{warning[:message]}"
  end

  puts "Skipped agents: #{result.skipped_agents.join(', ')}"
end
```

## API Reference

### Swarm Methods

```ruby
# Create snapshot
snapshot = swarm.snapshot
# => SwarmSDK::Snapshot

# Restore from snapshot
result = swarm.restore(snapshot)
# => SwarmSDK::RestoreResult

# Also accepts hash or JSON string (backward compatible)
result = swarm.restore(hash)
result = swarm.restore(json_string)
```

### Workflow Methods

Same API as Swarm:

```ruby
snapshot = orchestrator.snapshot
result = orchestrator.restore(snapshot)
```

### Snapshot Class

```ruby
# Instance methods
snapshot.to_hash                      # => Hash
snapshot.to_json(pretty: true)        # => String (JSON)
snapshot.write_to_file(path, pretty: true)  # => void

# Class methods (factory)
Snapshot.from_file(path)              # => Snapshot
Snapshot.from_json(json_string)       # => Snapshot
Snapshot.from_hash(hash)              # => Snapshot

# Metadata accessors
snapshot.version: 2.0.0"
snapshot.type                         # => "swarm" | "workflow"
snapshot.snapshot_at                  # => "2025-01-03T14:30:00Z"
snapshot.swarm_sdk_version            # => "2.1.3"
snapshot.agent_names                  # => ["agent1", "agent2"]
snapshot.delegation_instance_names    # => ["agent2@agent1"]

# Type checks
snapshot.swarm?                       # => true | false
snapshot.workflow?           # => true | false
```

### SnapshotFromEvents Class

```ruby
# Reconstruct snapshot from event stream
snapshot_hash = SwarmSDK::SnapshotFromEvents.reconstruct(events)
# => Hash (compatible with StateRestorer)

# Use reconstructed snapshot
swarm.restore(snapshot_hash)

# Or wrap in Snapshot object
snapshot = SwarmSDK::Snapshot.from_hash(snapshot_hash)
snapshot.write_to_file("reconstructed.json")
```

**Parameters:**
- `events` - Array of event hashes with timestamps

**Returns:** Hash in StateSnapshot format

**Requirements:**
- Events must have `:timestamp`, `:agent`, `:type` fields
- Events are automatically sorted by timestamp

### RestoreResult Class

```ruby
# Status checks
result.success?                       # => Boolean
result.partial_restore?               # => Boolean
result.summary                        # => String

# Details
result.warnings                       # => Array<Hash>
result.skipped_agents                 # => Array<Symbol>
result.skipped_delegations            # => Array<String>
```

## Use Cases

### Web Applications

```ruby
# Rails controller
class SwarmSessionsController < ApplicationController
  def create
    swarm = build_swarm_from_config
    result = swarm.execute(params[:prompt])

    # Save snapshot to session
    snapshot = swarm.snapshot
    session[:swarm_snapshot] = snapshot.to_hash

    render json: { result: result.content }
  end

  def continue
    # Restore from session
    swarm = build_swarm_from_config
    snapshot = SwarmSDK::Snapshot.from_hash(session[:swarm_snapshot])
    swarm.restore(snapshot)

    # Continue conversation
    result = swarm.execute(params[:prompt])

    # Update snapshot
    snapshot = swarm.snapshot
    session[:swarm_snapshot] = snapshot.to_hash

    render json: { result: result.content }
  end
end
```

### Redis Storage

```ruby
class SwarmSessionManager
  def initialize(redis_client)
    @redis = redis_client
  end

  def save_session(user_id, swarm)
    snapshot = swarm.snapshot
    @redis.set("swarm:#{user_id}", snapshot.to_json(pretty: false))
    @redis.expire("swarm:#{user_id}", 3600) # 1 hour TTL
  end

  def load_session(user_id, swarm)
    json_data = @redis.get("swarm:#{user_id}")
    return nil unless json_data

    snapshot = SwarmSDK::Snapshot.from_json(json_data)
    swarm.restore(snapshot)
  end
end
```

### Database Storage

```ruby
# ActiveRecord model
class SwarmSession < ApplicationRecord
  # Schema: user_id:integer, snapshot_data:jsonb, created_at:datetime

  def save_snapshot(swarm)
    snapshot = swarm.snapshot
    update!(snapshot_data: snapshot.to_hash)
  end

  def restore_to(swarm)
    snapshot = SwarmSDK::Snapshot.from_hash(snapshot_data)
    swarm.restore(snapshot)
  end
end

# Usage
session = SwarmSession.find_by(user_id: current_user.id)
swarm = build_swarm_from_config
session.restore_to(swarm)
```

### Checkpoint/Rollback

```ruby
# Save checkpoints during long-running tasks
checkpoints = []

swarm = SwarmSDK.build { ... }

# Phase 1
result = swarm.execute("Design database schema")
checkpoints << swarm.snapshot
checkpoints.last.write_to_file("checkpoint_1.json")

# Phase 2
result = swarm.execute("Implement API endpoints")
checkpoints << swarm.snapshot
checkpoints.last.write_to_file("checkpoint_2.json")

# Something went wrong, rollback to checkpoint 1
snapshot = SwarmSDK::Snapshot.from_file("checkpoint_1.json")
swarm.restore(snapshot)

# Retry phase 2 with different approach
result = swarm.execute("Implement API endpoints using different pattern")
```

### Workflow Workflows

```ruby
orchestrator = SwarmSDK::Workflow.new(
  swarm_name: "Dev Workflow",
  agent_definitions: { planner: planner_def, coder: coder_def },
  nodes: { planning: planning_node, coding: coding_node },
  start_node: :planning
)

# Execute workflow
result = orchestrator.execute("Build user registration")

# Save snapshot
snapshot = orchestrator.snapshot
snapshot.write_to_file("workflow_session.json")

# === Later, new process ===

# Restore and continue
orchestrator = SwarmSDK::Workflow.new(...)  # Same config
snapshot = SwarmSDK::Snapshot.from_file("workflow_session.json")
orchestrator.restore(snapshot)

# Continue workflow
result = orchestrator.execute("Add email verification")
```

## Advanced Topics

### Handling Configuration Mismatches

When your swarm config changes (agent renamed/removed), restore handles it gracefully:

```ruby
# Original config had agents: backend, frontend, database
# New config only has: backend, frontend

snapshot = SwarmSDK::Snapshot.from_file("old_session.json")
result = swarm.restore(snapshot)

if result.partial_restore?
  puts result.summary
  # => "Snapshot restored with warnings. 1 agents skipped, 1 delegation instances skipped."

  result.warnings.each do |warning|
    case warning[:type]
    when :agent_not_found
      puts "⚠️ Agent '#{warning[:agent]}' no longer exists"
      puts "   #{warning[:message]}"
    when :delegation_instance_not_restorable
      puts "⚠️ Delegation '#{warning[:instance]}' can't be restored"
      puts "   #{warning[:message]}"
    end
  end

  # Decide whether to proceed
  if result.skipped_agents.size > 2
    puts "Too many agents missing, aborting"
    exit 1
  end
end

# Continue with partial state
swarm.execute("Continue work with available agents")
```

### Multiple Storage Backends

```ruby
# File storage
snapshot.write_to_file("snapshots/session_123.json")

# Redis storage
redis.set("snapshot:123", snapshot.to_json(pretty: false))

# PostgreSQL storage
DB[:snapshots].insert(
  session_id: 123,
  data: Sequel.pg_jsonb(snapshot.to_hash)
)

# S3 storage
s3.put_object(
  bucket: "my-snapshots",
  key: "session_123.json",
  body: snapshot.to_json
)
```

### Snapshot Inspection

```ruby
snapshot = SwarmSDK::Snapshot.from_file("session.json")

# Check what's in the snapshot
puts "Type: #{snapshot.type}"
puts "Created: #{snapshot.snapshot_at}"
puts "Agents: #{snapshot.agent_names.join(', ')}"
puts "Delegations: #{snapshot.delegation_instance_names.join(', ')}"

# Inspect raw data
data = snapshot.to_hash
puts "Message count: #{data[:agents][:backend][:conversation].size}"
puts "Scratchpad entries: #{data[:scratchpad].keys.size}"

# Verify compatibility before restoring
unless snapshot.agent_names.all? { |name| swarm.agent_names.include?(name.to_sym) }
  puts "⚠️ Snapshot contains agents not in current config"
end
```

### Atomic File Writes

Snapshots use atomic writes to prevent corruption:

```ruby
# Write to temp file, then rename
# Pattern: session.json.tmp.PID.TIMESTAMP.RANDOM
snapshot.write_to_file("session.json")

# Even if process crashes during write:
# - session.json is never corrupted (atomic rename)
# - Temp file is cleaned up on next write
# - Multiple processes can write different files safely
```

### Content Digest Verification

Snapshots include SHA256 digests of all read files and memory entries:

```ruby
# Agent reads file
swarm.execute("Read config.yml and update database settings")

# Snapshot includes digest
snapshot = swarm.snapshot
hash = snapshot.to_hash
hash[:read_tracking][:backend]["config.yml"]
# => "a1b2c3d4e5f67890abcdef..." (SHA256 digest)

# File externally modified
File.write("config.yml", "completely different content")

# Restore in new process
swarm2 = SwarmSDK.build { ... }
swarm2.restore(snapshot)

# Agent tries to edit without re-reading
swarm2.execute("Edit config.yml to change port")
# => Agent must re-read file first (digest doesn't match)
# => Prevents editing based on stale content from LLM memory
```

## API Reference

### Swarm#snapshot

Create a snapshot of current conversation state.

```ruby
snapshot = swarm.snapshot
# => SwarmSDK::Snapshot
```

**Returns**: `Snapshot` object

**Captures**:
- All agent conversations
- Agent context state
- Delegation conversations
- Scratchpad contents
- Read tracking with digests
- Memory read tracking with digests

### Swarm#restore

Restore conversation state from snapshot.

```ruby
# Default: use current system prompts from config
result = swarm.restore(snapshot)
# => SwarmSDK::RestoreResult

# Advanced: use historical system prompts from snapshot
result = swarm.restore(snapshot, preserve_system_prompts: true)
# => SwarmSDK::RestoreResult
```

**Parameters**:
- `snapshot` - `Snapshot` object, hash, or JSON string
- `preserve_system_prompts` - Boolean, default `false`
  - `false` (default): Use current system prompts from agent definitions
  - `true`: Use historical system prompts from snapshot

**Returns**: `RestoreResult` object

**Requirements**:
- Swarm must have same agents (by name) as snapshot
- With `preserve_system_prompts: false` (default):
  - System prompts come from current config (YAML + SDK defaults + plugins)
  - Allows prompt iteration without creating new sessions
- With `preserve_system_prompts: true`:
  - System prompts come from snapshot (historical)
  - Exact reproducibility for debugging/auditing

### Snapshot.from_file

Load snapshot from JSON file.

```ruby
snapshot = SwarmSDK::Snapshot.from_file("session.json")
# => SwarmSDK::Snapshot
```

**Parameters**:
- `path` - File path to JSON file

**Returns**: `Snapshot` object

### Snapshot.from_json

Create snapshot from JSON string.

```ruby
snapshot = SwarmSDK::Snapshot.from_json(json_string)
# => SwarmSDK::Snapshot
```

**Parameters**:
- `json_string` - JSON string

**Returns**: `Snapshot` object

### Snapshot.from_hash

Create snapshot from hash.

```ruby
snapshot = SwarmSDK::Snapshot.from_hash(hash)
# => SwarmSDK::Snapshot
```

**Parameters**:
- `hash` - Hash with snapshot data

**Returns**: `Snapshot` object

### Snapshot#to_hash

Convert snapshot to hash.

```ruby
hash = snapshot.to_hash
# => Hash
```

**Returns**: Hash with all snapshot data

### Snapshot#to_json

Convert snapshot to JSON string.

```ruby
json = snapshot.to_json
# => String (pretty-printed JSON)

json = snapshot.to_json(pretty: false)
# => String (compact JSON)
```

**Parameters**:
- `pretty` - Boolean, default true

**Returns**: JSON string

### Snapshot#write_to_file

Write snapshot to JSON file with atomic write protection.

```ruby
snapshot.write_to_file("session.json")
snapshot.write_to_file("session.json", pretty: false)
```

**Parameters**:
- `path` - File path
- `pretty` - Boolean, default true (pretty-print JSON)

**Behavior**: Uses atomic write (temp file + rename) to prevent corruption

## Use Cases

### Long-Running Tasks

```ruby
def process_large_codebase(swarm, files)
  files.each_slice(10).with_index do |batch, i|
    swarm.execute("Process files: #{batch.join(', ')}")

    # Checkpoint every 10 files
    snapshot = swarm.snapshot
    snapshot.write_to_file("checkpoint_#{i}.json")
  end
end

# If process crashes, resume from last checkpoint
snapshot = SwarmSDK::Snapshot.from_file("checkpoint_5.json")
swarm = build_swarm
swarm.restore(snapshot)
process_large_codebase(swarm, remaining_files)
```

### Multi-User Sessions

```ruby
class UserSession
  def initialize(user_id)
    @user_id = user_id
    @snapshot_path = "sessions/#{user_id}.json"
  end

  def execute(prompt)
    swarm = build_user_swarm

    # Restore previous session if exists
    if File.exist?(@snapshot_path)
      snapshot = SwarmSDK::Snapshot.from_file(@snapshot_path)
      swarm.restore(snapshot)
    end

    # Execute prompt
    result = swarm.execute(prompt)

    # Save updated snapshot
    snapshot = swarm.snapshot
    snapshot.write_to_file(@snapshot_path)

    result
  end
end
```

### Background Jobs

```ruby
class SwarmJob
  def perform(job_id, prompt)
    # Load snapshot from previous job iteration
    snapshot_key = "job:#{job_id}:snapshot"

    swarm = build_swarm
    if redis.exists?(snapshot_key)
      json = redis.get(snapshot_key)
      snapshot = SwarmSDK::Snapshot.from_json(json)
      swarm.restore(snapshot)
    end

    # Execute work
    result = swarm.execute(prompt)

    # Save snapshot for next iteration
    snapshot = swarm.snapshot
    redis.set(snapshot_key, snapshot.to_json(pretty: false))
    redis.expire(snapshot_key, 86400) # 24 hours

    result
  end
end
```

### Testing

```ruby
class SwarmTest < Minitest::Test
  def test_snapshot_restore_preserves_context
    swarm = SwarmSDK.build { ... }
    swarm.execute("Initial task")

    # Take snapshot
    snapshot = swarm.snapshot

    # Create new swarm and restore
    swarm2 = SwarmSDK.build { ... }  # Same config
    result = swarm2.restore(snapshot)

    assert result.success?
    assert_equal swarm.agent(:backend).messages.size,
                 swarm2.agent(:backend).messages.size
  end
end
```

## Advanced Topics

### Snapshot Versioning

Track multiple snapshots per session:

```ruby
class VersionedSnapshots
  def initialize(session_id)
    @session_id = session_id
    @version = 0
  end

  def save(swarm)
    @version += 1
    snapshot = swarm.snapshot
    snapshot.write_to_file("sessions/#{@session_id}_v#{@version}.json")
  end

  def load(version)
    SwarmSDK::Snapshot.from_file("sessions/#{@session_id}_v#{version}.json")
  end

  def latest
    load(@version)
  end
end
```

### Snapshot Compression

For large conversations, compress snapshots:

```ruby
require "zlib"

# Save compressed
snapshot = swarm.snapshot
json = snapshot.to_json(pretty: false)
compressed = Zlib::Deflate.deflate(json)
File.binwrite("session.json.gz", compressed)

# Load compressed
compressed = File.binread("session.json.gz")
json = Zlib::Inflate.inflate(compressed)
snapshot = SwarmSDK::Snapshot.from_json(json)
```

### Snapshot Diff

Compare two snapshots:

```ruby
def snapshot_diff(snapshot1, snapshot2)
  h1 = snapshot1.to_hash
  h2 = snapshot2.to_hash

  {
    agents_added: snapshot2.agent_names - snapshot1.agent_names,
    agents_removed: snapshot1.agent_names - snapshot2.agent_names,
    message_count_changes: snapshot2.agent_names.map { |name|
      count1 = h1.dig(:agents, name.to_sym, :conversation)&.size || 0
      count2 = h2.dig(:agents, name.to_sym, :conversation)&.size || 0
      [name, count2 - count1]
    }.to_h
  }
end
```

### Scratchpad Persistence

Scratchpad is volatile by default, but snapshot preserves it:

```ruby
# Session 1
swarm = SwarmSDK.build { ... }
swarm.execute("Write progress to scratchpad://tasks/auth.md")
snapshot = swarm.snapshot

# Scratchpad content is in snapshot
hash = snapshot.to_hash
hash[:scratchpad]["tasks/auth.md"]
# => { content: "...", title: "...", updated_at: "...", size: 123 }

# Session 2 - scratchpad content restored
swarm2 = SwarmSDK.build { ... }
swarm2.restore(snapshot)
swarm2.execute("Read scratchpad://tasks/auth.md")
# => Agent sees content from previous session
```

**Note**: Workflow doesn't snapshot scratchpad because each node creates its own fresh scratchpad.

## Troubleshooting

### Partial Restore Warnings

**Problem**: Getting warnings about skipped agents

**Solution**: Ensure swarm configuration matches snapshot

```ruby
result = swarm.restore(snapshot)
if result.partial_restore?
  # Check which agents are missing
  puts "Skipped: #{result.skipped_agents.join(', ')}"

  # Option 1: Update config to include missing agents
  # Option 2: Accept partial restore and continue
  # Option 3: Reject and don't proceed
end
```

### Agent Not Found Error

**Problem**: Agent in snapshot doesn't exist in current swarm

**Cause**: Configuration changed between snapshot and restore

**Solution**:
```ruby
# Before restoring, check compatibility
snapshot = SwarmSDK::Snapshot.from_file("session.json")
current_agents = swarm.agent_names
snapshot_agents = snapshot.agent_names.map(&:to_sym)

missing = snapshot_agents - current_agents
if missing.any?
  puts "⚠️ Snapshot contains agents not in current config: #{missing.join(', ')}"
  puts "Add these agents to your config or accept partial restore"
end

result = swarm.restore(snapshot)
# Missing agents will be skipped with warnings
```

### Version Mismatch

**Problem**: `Unsupported snapshot version: X.X.X`

**Cause**: Snapshot created with different SwarmSDK version

**Solution**:
- Update SwarmSDK to compatible version
- Or migrate snapshot to new format (when migration guide available)

### Type Mismatch

**Problem**: `Snapshot type 'swarm' doesn't match orchestration type 'workflow'`

**Cause**: Trying to restore swarm snapshot into Workflow (or vice versa)

**Solution**: Use correct orchestration type that matches snapshot

### Stale Content After Restore

**Problem**: Agent edits file that was modified externally

**This is prevented automatically!** Digest tracking ensures agents must re-read files if content changed:

```ruby
# Before snapshot
swarm.execute("Read and analyze config.yml")
snapshot = swarm.snapshot

# File modified externally
File.write("config.yml", "new content")

# After restore
swarm2.restore(snapshot)
swarm2.execute("Update config.yml")
# => Agent must re-read config.yml first
# => "Cannot edit config.yml without reading it first"
```

### Empty Messages After Restore

**Problem**: Agent has fewer messages after restore

**Likely Causes**:
1. Accessing agent before calling `restore()` (triggers initialization)
2. JSON parsing without `symbolize_names: true`

**Solution**:
```ruby
# ❌ Wrong - agent initialized before restore
swarm = SwarmSDK.build { ... }
agent = swarm.agent(:backend)  # Initializes agent
swarm.restore(snapshot)        # Restores but agent already has system message

# ✅ Correct - restore before accessing agents
swarm = SwarmSDK.build { ... }
swarm.restore(snapshot)        # Restores to uninitialized agents
agent = swarm.agent(:backend)  # Access after restore

# Also ensure proper JSON parsing
snapshot = SwarmSDK::Snapshot.from_json(json_string)  # Handles this automatically
```

## Best Practices

### 1. Always Use Same Configuration

```ruby
# Save config hash with snapshot for verification
config_hash = Digest::SHA256.hexdigest(swarm_yaml_content)

snapshot_data = {
  config_hash: config_hash,
  snapshot: swarm.snapshot.to_hash
}

# On restore, verify config hasn't changed
saved_hash = snapshot_data[:config_hash]
current_hash = Digest::SHA256.hexdigest(swarm_yaml_content)

unless saved_hash == current_hash
  puts "⚠️ Configuration has changed since snapshot"
end
```

### 2. Set Expiration on Stored Snapshots

```ruby
# Redis
redis.set("snapshot:#{id}", snapshot.to_json)
redis.expire("snapshot:#{id}", 7.days.to_i)

# Database
SwarmSession.where("created_at < ?", 30.days.ago).delete_all
```

### 3. Validate Restore Results

```ruby
result = swarm.restore(snapshot)

# Don't silently ignore partial restores
if result.partial_restore?
  logger.warn("Partial snapshot restore: #{result.summary}")

  # Notify user or take corrective action
  if result.skipped_agents.include?(:critical_agent)
    raise "Critical agent missing from restore"
  end
end
```

### 4. Use Pretty JSON for Files, Compact for Storage

```ruby
# Development/debugging - use pretty JSON
snapshot.write_to_file("debug_session.json", pretty: true)

# Production Redis/DB - use compact JSON
redis.set("snapshot:#{id}", snapshot.to_json(pretty: false))
```

### 5. Restore Before Accessing Agents

```ruby
# ✅ Correct order
swarm = SwarmSDK.build { ... }
swarm.restore(snapshot)
agent = swarm.agent(:backend)  # Accesses after restore

# ❌ Wrong order
swarm = SwarmSDK.build { ... }
agent = swarm.agent(:backend)  # Initializes agent first
swarm.restore(snapshot)        # Restore won't work correctly
```

## Security Considerations

### Snapshot Content

Snapshots contain:
- Full conversation history (may include sensitive data)
- File paths that were read
- Scratchpad content

**Recommendations**:
- Encrypt snapshots if storing sensitive conversations
- Use appropriate access controls on snapshot storage
- Implement data retention policies
- Don't commit snapshots to version control

### Digest Verification

Digest tracking prevents:
- Editing files that changed externally (prevents data corruption)
- Time-of-check-time-of-use (TOCTOU) bugs
- Stale content edits based on LLM memory

## Examples

See `examples/snapshot_demo.rb` for a complete working example.

## Related Documentation

- [Getting Started](getting-started.md) - Basic SwarmSDK usage
- [Complete Tutorial](complete-tutorial.md) - Full SwarmSDK tutorial
- [Rails Integration](rails-integration.md) - Using snapshots in Rails apps
- [Composable Swarms](composable-swarms.md) - Sub-swarm snapshots
