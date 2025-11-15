# Changelog

All notable changes to SwarmMemory will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Updated documentation to reference `Workflow` instead of `NodeOrchestrator`
- Memory configuration preserved when agents are cloned in `Workflow` (formerly `NodeOrchestrator`)
- No functional changes - fully compatible with SwarmSDK refactoring

## [2.1.3] - 2025-11-06

### Added

- **Memory Read Tracking in Events**: MemoryRead tool now includes digest in tool_result events
  - **`metadata.read_digest`** - SHA256 digest of entry content added to tool_result events
  - **`metadata.read_path`** - Entry path added to tool_result events
  - **Enables snapshot reconstruction** - Complete memory_read_tracking state recoverable from events
  - **Event sourcing support** - Memory state can be reconstructed from event logs
  - **Cross-gem coordination** - Works seamlessly with SwarmSDK's SnapshotFromEvents

### Changed

- **StorageReadTracker returns digest**: `register_read` now returns SHA256 digest string
  - **Enables**: Digest extraction after MemoryRead execution for event metadata
  - **Backward compatible**: Return value wasn't previously used
  - **Integration**: Used by SwarmSDK to populate tool_result event metadata

## [2.1.2]

### Changed
- **Stub redirect logic moved to Storage layer** - Architectural improvement for adapter-agnostic redirects
  - Redirect following moved from `FilesystemAdapter` to `Storage#read_entry`
  - Uses metadata-based detection (`stub: true`, `redirect_to`) instead of content parsing
  - All future adapters (PostgreSQL, Redis, S3) get redirect support for free
  - Improved error handling with helpful diagnostic messages
  - Detects circular redirects immediately with full cycle path
  - Enforces depth limit (5 redirects) to prevent infinite chains
  - Added comprehensive test suite with 10 tests covering all edge cases
  - Added validation to `Defragmenter#create_stub` to prevent malformed stubs

## [2.1.1]

### Added
- **250-word content limit**: MemoryWrite now validates content length
  - Enforces 250-word maximum per memory entry
  - Encourages focused, searchable entries instead of large documents
  - Helpful error message guides users to split large content into multiple linked memories
  - Promotes better organization through multiple focused entries with `related` field links

- **MemoryGlob result truncation**: Prevents overwhelming output from broad searches
  - Maximum 1000 results per query (matches Glob tool behavior)
  - System reminder added when results are truncated
  - Encourages users to use more specific patterns
  - Sorted by most recently modified (first 1000 shown)

### Changed
- **Memory Assistant prompt improvements**: Updated examples and guidance
  - Updated examples from 5000-word to 250-word entries
  - Better illustrates recommended memory organization patterns
  - Shows proper use of `related` field for linking split content

- **Memory Researcher prompt enhancements**: Comprehensive updates for better knowledge extraction
  - Clarified "learning" workflow: gather information → store thoroughly in memory
  - Added CRITICAL reminders about available memory tools (only Memory* tools, no "MemorySearch")
  - Emphasized mandatory `type` parameter in all MemoryWrite calls
  - Expanded guidance on when to create skills vs concepts/facts/experiences
  - Reinforced thoroughness: capture ALL details, don't summarize away important information
  - Better guidance on splitting large content into multiple focused, linked memories (each <250 words)
  - Clarified LoadSkill vs MemoryRead: LoadSkill for DOING tasks, MemoryRead for explaining
  - Enhanced research-specific workflows and extraction patterns
  - Improved quality standards and verification guidelines
  - Stronger emphasis on building a knowledge graph through comprehensive tagging and linking

## [2.1.0] - 2025-10-27

### Changed
- **BREAKING CHANGE: Hierarchical directory storage**
  - Memory entries are now stored in actual directories instead of flattened paths with `--` separators
  - **Before**: `concept--ruby--classes.md` (flattened with `--` separators)
  - **After**: `concept/ruby/classes.md` (hierarchical directories)
  - **Impact**: Existing memory storage will NOT be automatically migrated
  - **Migration**: Clear existing memory or manually reorganize files into directory structure
  - **Benefits**:
    - Native Dir.glob works efficiently (no need to simulate directory semantics)
    - Glob patterns like `fact/*` now correctly match only direct children, not nested paths
    - Better filesystem semantics - paths behave like real directories
    - Improved performance for glob operations
    - More intuitive file browsing in file managers

### Added
- **Path parameter for MemoryGrep**: Limit grep searches to specific paths
  - Example: `MemoryGrep(pattern: "TODO", path: "concept/")` searches only concepts
  - Supports directory paths (`fact/api/`), subdirectories, and specific files
  - Works with all output modes (files_with_matches, content, count)
  - Directory-style filtering: `fact/api` matches `fact/api/...` but not `fact/api-design/...`

### Fixed
- **MemoryGlob path matching**: Fixed bug where single-level wildcards matched nested paths
  - `fact/*` now correctly matches only `fact/api.md`, not `fact/people/john.md`
  - `fact/**` correctly matches all nested entries recursively
  - Glob semantics now match standard filesystem glob behavior

### Added

#### Core Architecture

- **Complete Filesystem Memory System** - Real files for agent memory
  - 4 fixed categories: `concept/`, `fact/`, `skill/`, `experience/`
  - Split storage: `.md` (content), `.yml` (metadata), `.emb` (embeddings)
  - Flattened paths with `--` separator for Git-friendly structure
  - Hit tracking in metadata for archival candidate detection
  - Stubs and redirects for merged/moved entries (`# merged →`, `# moved →`)

- **Plugin System Integration** - SwarmMemory integrates with SwarmSDK via plugin architecture
  - `SwarmMemory::Integration::SDKPlugin` implements `SwarmSDK::Plugin` interface
  - Auto-registers with SwarmSDK when loaded via `require "swarm_memory"`
  - Provides tools, storage, and system prompt contributions
  - Zero coupling: SwarmSDK works standalone without SwarmMemory
  - Lifecycle hooks: `on_agent_initialized`, `on_swarm_started`, `on_user_message`

- **Adapter Plugin Registry** - Pluggable storage backends
  - `SwarmMemory::Adapters::Base.register_adapter()` for custom adapters
  - Third-party gems can register custom storage implementations
  - Adapter pattern decouples storage from interface
  - Current implementation: `FilesystemAdapter` (real .md/.yml/.emb files)

#### Memory Modes System

- **Three Operational Modes** - Mode-specific prompts and tools
  - **Retrieval Mode** - Read-only (MemoryRead, MemoryGlob, MemoryGrep)
    - 88-line prompt focused on search strategies
    - Q&A agents accessing knowledge without modification
  - **Assistant Mode** - Read + Write + Edit + LoadSkill
    - 139-line prompt with writing guidelines and quality standards
    - Learning assistants that correct/update knowledge
    - Dynamic tool adaptation via LoadSkill
  - **Researcher Mode** - Full access (all 9 tools)
    - 201-line prompt with optimization strategies
    - Knowledge extraction, deep optimization, graph building
    - Includes MemoryMultiEdit, MemoryDelete, MemoryDefrag
  - Configure via `memory.mode` in agent config

#### Semantic Search

- **Hybrid Semantic Search** - Combined semantic + keyword matching
  - **SemanticIndex** - Adapter-agnostic semantic search abstraction
  - **Hybrid Scoring**: 50% semantic similarity + 50% keyword tag matching
  - Improved recall accuracy from 43.8% → 78.8% for skill discovery
  - Configurable weights via `SWARM_MEMORY_SEMANTIC_WEIGHT` / `SWARM_MEMORY_KEYWORD_WEIGHT`
  - Pure semantic mode for relationship detection (no keyword pollution)
  - Works with any storage adapter

- **Adaptive Discovery Thresholds** - Query-length based thresholds
  - Short queries (< 10 words): Lower threshold (0.25 default) for broader matching
  - Normal queries (≥ 10 words): Higher threshold (0.35 default) for precision
  - Configurable via environment variables:
    - `SWARM_MEMORY_DISCOVERY_THRESHOLD` (normal queries)
    - `SWARM_MEMORY_DISCOVERY_THRESHOLD_SHORT` (short queries)
    - `SWARM_MEMORY_ADAPTIVE_WORD_CUTOFF` (word count cutoff)

- **Improved Embeddings** - Optimized for search
  - Embeds title (highest weight) + tags + domain + first paragraph
  - Searchable text limit: 1200 chars (configurable via `SWARM_MEMORY_EMBEDDING_MAX_CHARS`)
  - 384-dimensional vectors via Informers gem
  - Model: sentence-transformers/multi-qa-MiniLM-L6-cos-v1 (~90MB ONNX)
  - Cached locally in `~/.informers/`
  - Binary packed `.emb` files for fast loading

#### Dual Discovery System

- **Automatic Skill Discovery** - Searches skills on every user message
  - Hybrid semantic+keyword search for relevant skills
  - System reminders with LoadSkill instructions
  - Parallel execution with Async
  - Top 3 results with match percentages
  - Structured logging for observability

- **Automatic Memory Discovery** - Searches concepts/facts/experiences
  - Hybrid semantic+keyword search for context
  - System reminders with MemoryRead suggestions
  - Runs in parallel with skill discovery
  - Separate reminders for skills vs knowledge

#### Tools

- **9 Memory Tools** - Complete CRUD + optimization
  - **MemoryWrite** - Store with 8 required metadata parameters
  - **MemoryRead** - Retrieve with JSON output, tracks reads
  - **MemoryEdit** - Exact string replacement (enforces read-before-edit)
  - **MemoryMultiEdit** - Sequential edits (all-or-nothing atomic)
  - **MemoryGlob** - Find by path pattern with sizes and titles
  - **MemoryGrep** - Search content (3 modes: files, content, count)
  - **MemoryDelete** - Remove entries with warnings
  - **MemoryDefrag** - 10 comprehensive optimization actions
  - **LoadSkill** - Dynamic tool swapping from skill entries

- **LoadSkill Tool** - Dynamic tool adaptation
  - Removes mutable tools (Read, Write, Edit, Bash, etc.)
  - Preserves immutable tools (Memory*, Think, Clock, LoadSkill, TodoWrite)
  - Adds skill's tools from metadata
  - Applies skill's permissions to new tools
  - Returns skill content with system reminder of new toolset
  - `ChatExtension` adds `remove_tool(name)` to `Agent::Chat`

- **MemoryDefrag Actions** - 10 comprehensive actions
  - **Read-Only Analysis:**
    - `analyze` - Health report (quality score 0-100)
    - `find_duplicates` - Text + semantic similarity (threshold: 0.85)
    - `find_low_quality` - Missing metadata, low confidence (quality < 50)
    - `find_archival_candidates` - Old, unused entries (age_days: 90)
    - `find_related` - Discover relationships (60-85% similarity range)
  - **Active Optimization (with dry_run support):**
    - `merge_duplicates` - Combine entries, create redirect stubs
    - `cleanup_stubs` - Remove old redirect files
    - `compact` - Delete low-value entries (quality < 20)
    - `link_related` - Create bidirectional links
    - `full` - Complete workflow with health tracking

- **Tool Description Enhancements** - Comprehensive, self-documenting
  - All tools have detailed descriptions with examples
  - Explicit "REQUIRED: Provide ALL X parameters" statements
  - Path structure enforcement (4 fixed categories only)
  - Usage examples, common mistakes, best practices
  - Parameter details moved from prompts to tool descriptions

#### Data Integrity

- **Cross-Process File Locking** - Prevents corruption
  - **Async::Semaphore** - Fiber-aware local concurrency control
  - **File.flock** - Cross-process exclusive write locks
  - Prevents corruption when defrag runs while agents write
  - Lock acquisition/release logged for debugging
  - Replaced Mutex with Async::Semaphore for fiber safety

- **Read-Before-Edit Enforcement** - Prevents blind overwrites
  - **StorageReadTracker** - Global registry of read files
  - MemoryEdit verifies MemoryRead was called first
  - Prevents modifications without context
  - Thread-safe with Mutex synchronization
  - Helpful error messages with instructions

- **Stubs & Redirects** - Non-destructive merging
  - Entries marked with `# merged →` or `# moved →` create auto-redirects
  - Automatic follow-redirects in read operations
  - Preserves old paths after merging/moving
  - Cleanup via `MemoryDefrag(action: "cleanup_stubs")`

#### CLI Integration

- **CLI Command Registry** - Third-party command registration
  - `SwarmCLI::CommandRegistry` for plugin commands
  - SwarmMemory registers `memory` command automatically
  - Seamless integration with swarm CLI

- **CLI Commands** - 5 memory management commands
  - `swarm memory setup` - Download embedding model (~90MB, one-time)
  - `swarm memory status` - Check if embeddings ready
  - `swarm memory model-path` - Show cache location
  - `swarm memory defrag DIRECTORY` - Optimize memory at directory
  - `swarm memory rebuild DIRECTORY` - Regenerate all embeddings
    - LLM retry logic (10 retries, 10-second delays)
    - Batch processing for efficiency

- **REPL Command** - Interactive defragmentation
  - `/defrag` - Discovers relationships and creates links
  - Automatic workflow: find_related → agent reviews → link_related

#### Skills System

- **Virtual Meta-Skills** - Built-in skills
  - Packaged with SwarmMemory gem (e.g., `skill/meta/deep-learning.md`)
  - No user storage cost
  - Act as templates and examples
  - Virtual entries in adapter (no disk files)

- **Skill Metadata Structure** - Complete skill definition
  - `type: skill` - Required for LoadSkill
  - `tools: [...]` - Required tools array
  - `permissions: {...}` - Tool-specific permissions
  - Standard memory metadata (tags, confidence, domain, etc.)

#### Search & Analysis

- **Relationship Discovery** - Automatic knowledge graph building
  - `find_related` - Discover entries with 60-85% semantic similarity
  - `link_related` - Create bidirectional links automatically
  - Pure semantic similarity (no keyword boost) for relationships
  - Skips already-linked pairs
  - Dry-run mode for preview

- **Quality Scoring** - Metadata completeness assessment
  - Type present: +20
  - Confidence set: +20
  - Tags present: +15
  - Related links: +15
  - Domain set: +10
  - Last verified: +10
  - High confidence bonus: +10
  - Max score: 100

- **Text Similarity Utilities**
  - Jaccard similarity for keyword overlap
  - Cosine similarity for embedding distance
  - Used in duplicate/relationship detection

#### Configuration

- **DSL Integration** - Ruby DSL support
  - `memory { mode :researcher; directory ".swarm/memory" }` syntax
  - `SwarmMemory::DSL::BuilderExtension` for Agent::Builder
  - `SwarmMemory::DSL::MemoryConfig` for configuration parsing

- **YAML Configuration** - Declarative config
  - `memory.mode` - retrieval | assistant | researcher
  - `memory.directory` - Storage location
  - `memory.adapter` - Storage backend (default: filesystem)
  - Parsed via `SwarmMemory::Integration::Configuration`

#### Observability

- **Logging & Events** - Structured logging
  - `semantic_skill_search` - Logs skill discovery results
  - `semantic_memory_search` - Logs memory discovery results
  - `memory_embedding_generated` - Logs searchable text
  - Shows hybrid scores (semantic + keyword breakdown)
  - Includes debug info (top results, tags, similarity scores)

### Changed

- **Storage Architecture** - Embeddings enabled by default
  - `Storage.new(adapter:, embedder:)` with InformersEmbedder
  - Exposes `storage.semantic_index` for semantic search
  - `build_searchable_text()` creates optimized embedding input
  - `extract_first_paragraph()` for content summarization

- **FilesystemAdapter** - Enhanced with semantic search
  - `semantic_search(embedding:, top_k:, threshold:)` method
  - `cosine_similarity()` calculation
  - Returns results with similarity scores and metadata
  - Uses in-memory embedding index for fast lookups
  - File locking for cross-process safety

- **Tool Parameter Handling** - Flexible input formats
  - MemoryWrite accepts both JSON strings (from LLMs) and Ruby arrays/hashes (from tests)
  - `parse_array_param()` and `parse_object_param()` helpers
  - Backward compatible with test suite

- **Memory Categories Enforcement** - Strict validation
  - All tools enforce 4 fixed categories in descriptions
  - All examples use only valid paths
  - INVALID examples listed to prevent creation
  - Path validation in parameter descriptions

- **Memory Prompts** - Mode-specific optimization
  - Base prompt: 845 → 88 lines (90% reduction)
  - Retrieval: 88 lines (search strategies)
  - Assistant: 139 lines (writing guidelines)
  - Researcher: 201 lines (optimization strategies)
  - Details moved to tool descriptions
  - Memory-first protocol prominently placed

### Removed

- **Old Registration System** - Replaced by plugin
  - `Tools::Registry.register_extension()` calls removed
  - Now uses `SwarmSDK::PluginRegistry.register()`

### Breaking Changes

⚠️ **Major breaking changes:**

1. **Plugin-based integration required**
   - SwarmMemory MUST be loaded after SwarmSDK
   - Auto-registration happens on require
   - No manual registration needed

2. **Embeddings enabled by default**
   - Storage now creates embeddings for all entries
   - Requires Informers gem for semantic search
   - `.emb` files created alongside `.md` and `.yml` files
   - Run `swarm memory setup` to download model (~90MB)

3. **Memory prompt location changed**
   - **Was**: Hardcoded path in SwarmSDK
   - **Now**: Plugin provides prompt via `system_prompt_contribution()`

4. **Memory modes required**
   - Must specify mode: retrieval | assistant | researcher
   - Different tools available per mode
   - Mode-specific prompts loaded dynamically

5. **MemoryWrite requires 8 parameters**
   - All parameters mandatory (no defaults)
   - file_path, content, title, type, confidence, tags, related, domain
   - Enforces metadata discipline

6. **MemoryEdit requires read-before-edit**
   - Must call MemoryRead before MemoryEdit
   - Tracked globally via StorageReadTracker
   - Error if attempting to edit unread file

## [2.0.0] - 2025-10-26

Initial release of SwarmMemory as separate gem.

Complete persistent memory system with:
- 4 fixed categories (concept, fact, skill, experience)
- 9 memory tools (Write, Read, Edit, MultiEdit, Delete, Glob, Grep, Defrag, LoadSkill)
- Hybrid semantic search (50% semantic + 50% keyword)
- 3 memory modes (retrieval, assistant, researcher)
- Cross-process file locking
- Automatic skill/memory discovery
- CLI commands for setup and management
- Plugin architecture for SwarmSDK integration
- Virtual meta-skills
- Relationship discovery and knowledge graph building

See SwarmSDK CHANGELOG for prior memory system history (was part of SwarmSDK v1).
