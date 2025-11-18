# Changelog

All notable changes to SwarmCLI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.4]

### Changed

- `ConfigLoader` now accepts both `SwarmSDK::Swarm` and `SwarmSDK::Workflow` instances from Ruby DSL files
  - Updated error messages to reference `Workflow` instead of `NodeOrchestrator`
  - Both swarms and workflows work seamlessly with CLI commands

## [2.1.3]

### Fixed

- **Interactive REPL spinner cleanup** - Fixed spinners not stopping properly
  - Bug: Spinners continued animating after swarm execution completed or on errors
  - Bug: REPL prompt would overlap with spinner animation, causing terminal corruption
  - Fix: Added `spinner_manager.stop_all()` after `execute_with_cancellation()` in all paths
  - Fix: Added defensive cleanup in `on_success()`, `on_error()`, and `run()` ensure block
  - Fix: Ensures spinners stop before displaying results, errors, or REPL prompt
  - Impact: Fixes 100% of interactive mode sessions

### Added

- **LLM API Error and Retry Event Handlers** - CLI now shows LLM API errors and retries
  - Added handler for `llm_retry_attempt` - Shows warning panel during retry attempts
  - Added handler for `llm_retry_exhausted` - Shows error panel when retries are exhausted
  - Added handler for `response_parse_error` - Shows error panel when response parsing fails
  - Displays attempt numbers (e.g., "attempt 2/3"), retry delays, error messages
  - Properly manages spinners during error display (stops "thinking" spinner, restarts "retrying" spinner)
  - Provides clear visibility into API rate limits, timeouts, and parsing errors

## [2.1.2]

### Changed

- **Internal: Updated to use new SwarmSDK loading API**
  - `ConfigLoader` now uses `SwarmSDK.load_file` instead of `SwarmSDK::Swarm.load`
  - `mcp serve` command updated to use `SwarmSDK.load_file`
  - No user-facing changes - all CLI commands work identically
  - Benefits from improved SDK separation (SDK handles strings, CLI handles files)

## [2.1.1]

### Fixed
- **`swarm mcp tools` command initialization** - Fixed crash on startup
  - Bug: Used non-existent `SwarmSDK::Scratchpad` class
  - Fix: Changed to `SwarmSDK::Tools::Stores::ScratchpadStorage` (correct class)
  - Added comprehensive test suite to prevent similar initialization bugs
  - Tests verify command initializes without errors

## [2.1.0]
- Bump gem version with the rest of the gems.

## [2.0.3] - 2025-10-26

### Added
- **`/defrag` Slash Command** - Automated memory defragmentation workflow
  - Discovers semantically related memory entries (60-85% similarity)
  - Creates bidirectional links to build knowledge graph
  - Runs `MemoryDefrag(action: "find_related")` then `MemoryDefrag(action: "link_related")`
  - Accessible via `/defrag` in interactive REPL

## [2.0.2]

### Added
- **Multi-line Input Support** - Interactive REPL now supports multi-line input
  - Press Option+Enter (or ESC then Enter) to add newlines without submitting
  - Press Enter to submit your message
  - Updated help documentation with input tips
- **Request Cancellation** - Press Ctrl+C to cancel an ongoing LLM request
  - Cancels the current request and returns to the prompt
  - Ctrl+C at the prompt still exits the REPL (existing behavior preserved)
  - Uses Async task cancellation for clean interruption

## [2.0.1] - Fri, Oct 17 2025

### Fixed

- Fixed interactive REPL file completion dropdown not closing after typing space following a Tab completion
- Fixed navigation mode not exiting when regular keys are typed after Tab completion

## [2.0.0] - Fri, Oct 17 2025

Initial release of SwarmCLI.

See https://github.com/parruda/claude-swarm/pull/137
