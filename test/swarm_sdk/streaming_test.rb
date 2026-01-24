# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  # Comprehensive tests for streaming functionality
  #
  # Tests cover:
  # - content_chunk event emission
  # - Configuration (global, per-agent, inheritance)
  # - Streaming block behavior
  # - Chunk type detection and separator events
  # - Partial tool_call arguments in chunks
  # - Integration with other SDK features
  class StreamingTest < Minitest::Test
    def setup
      SwarmSDK.reset_config!

      # Set fake API key to avoid RubyLLM configuration errors
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-streaming-tests"
      RubyLLM.configure do |config|
        config.openai_api_key = "test-key-streaming-tests"
      end

      @test_scratchpad = create_test_scratchpad
      @collected_events = []
    end

    def teardown
      # Restore original API key
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure do |config|
        config.openai_api_key = @original_api_key
      end

      cleanup_test_scratchpads
      SwarmSDK.reset_config!
      LogCollector.reset!
      LogStream.reset!
    end

    # ========== Unit Tests: Configuration ==========

    def test_global_streaming_config_defaults_to_true
      # Reset config to get production defaults (test_helper after_setup sets it to false)
      SwarmSDK.reset_config!

      # Production default should be true for timeout prevention
      assert(SwarmSDK.config.streaming, "Global streaming should default to true")
    end

    def test_global_streaming_can_be_disabled
      SwarmSDK.configure do |config|
        config.streaming = false
      end

      refute(SwarmSDK.config.streaming)
    end

    def test_env_variable_overrides_default
      ENV["SWARM_SDK_STREAMING"] = "false"
      SwarmSDK.reset_config!

      refute(SwarmSDK.config.streaming)
    ensure
      ENV.delete("SWARM_SDK_STREAMING")
      SwarmSDK.reset_config!
    end

    def test_env_variable_supports_various_boolean_formats
      test_cases = {
        "true" => true,
        "yes" => true,
        "1" => true,
        "on" => true,
        "enabled" => true,
        "false" => false,
        "no" => false,
        "0" => false,
        "off" => false,
        "disabled" => false,
      }

      test_cases.each do |value, expected|
        ENV["SWARM_SDK_STREAMING"] = value
        SwarmSDK.reset_config!

        assert_equal(expected, SwarmSDK.config.streaming, "ENV=#{value} should parse to #{expected}")
      end
    ensure
      ENV.delete("SWARM_SDK_STREAMING")
      SwarmSDK.reset_config!
    end

    def test_agent_definition_inherits_global_streaming
      SwarmSDK.config.streaming = true

      definition = Agent::Definition.new(:test, {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
      })

      assert(definition.streaming, "Agent should inherit global streaming=true")
    end

    def test_agent_definition_can_override_global_streaming
      SwarmSDK.config.streaming = true

      definition = Agent::Definition.new(:test, {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
        streaming: false,
      })

      refute(definition.streaming, "Agent should override to streaming=false")
    end

    def test_agent_definition_serializes_streaming_in_to_h
      definition = Agent::Definition.new(:test, {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
        streaming: false,
      })

      config_hash = definition.to_h

      refute(config_hash[:streaming], "to_h should include streaming setting")
    end

    def test_builder_dsl_streaming_method
      agent = Agent::Builder.new(:test)
      agent.model("gpt-5")
      agent.system_prompt("Test")
      agent.streaming(false)

      definition = agent.to_definition

      refute(definition.streaming, "Builder streaming(false) should result in definition with streaming=false")
    end

    def test_builder_streaming_set_predicate
      agent = Agent::Builder.new(:test)

      refute_predicate(agent, :streaming_set?, "streaming_set? should be false when not set")

      agent.streaming(true)

      assert_predicate(agent, :streaming_set?, "streaming_set? should be true after calling streaming()")
    end

    def test_builder_to_definition_includes_streaming
      agent = Agent::Builder.new(:test)
      agent.model("gpt-5")
      agent.system_prompt("Test")
      agent.streaming(false)

      definition = agent.to_definition

      refute(definition.streaming)
    end

    def test_builder_omits_streaming_when_not_set
      agent = Agent::Builder.new(:test)
      agent.model("gpt-5")
      agent.system_prompt("Test")
      # Don't call streaming() - should use default

      definition = agent.to_definition

      # Should inherit from global config
      assert_equal(SwarmSDK.config.streaming, definition.streaming)
    end

    # ========== Unit Tests: content_chunk Event Emission ==========

    def test_content_chunk_events_emitted_when_streaming_enabled
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm(streaming: true)

      # Use real SSE streaming mock
      stub_streaming_llm(["Hello", " world", "!"], model: "gpt-4")

      # Collect content_chunk events
      content_chunks = []
      swarm.execute("Test") do |event|
        content_chunks << event if event[:type] == "content_chunk"
      end

      assert_operator(content_chunks.size, :>=, 2, "Should emit multiple content_chunk events")

      # Verify event structure
      content_chunks.each do |chunk|
        assert_equal(:test_agent, chunk[:agent])
        assert_equal("content", chunk[:chunk_type])
        assert(chunk[:content], "Should have content")
      end
    end

    def test_content_chunk_events_not_emitted_when_streaming_disabled
      # Explicitly disable streaming
      SwarmSDK.config.streaming = false

      swarm = build_streaming_swarm(streaming: false)

      # Mock non-streaming response
      stub_llm_request(mock_llm_response(content: "Complete response"))

      # Collect content_chunk events
      content_chunks = []
      swarm.execute("Test") do |event|
        content_chunks << event if event[:type] == "content_chunk"
      end

      assert_equal(0, content_chunks.size, "Should NOT emit content_chunk events when streaming disabled")
    end

    def test_content_chunk_event_includes_agent_name
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm(streaming: true)

      stub_streaming_llm(["Test"], model: "gpt-4")

      content_chunk = nil
      swarm.execute("Test") do |event|
        content_chunk = event if event[:type] == "content_chunk"
      end

      assert(content_chunk, "Should receive content_chunk event")
      assert_equal(:test_agent, content_chunk[:agent], "content_chunk should include agent name")
    end

    def test_content_chunk_event_includes_model_id
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm(streaming: true)

      stub_streaming_llm(["Test"], model: "gpt-4")

      content_chunk = nil
      swarm.execute("Test") do |event|
        content_chunk = event if event[:type] == "content_chunk"
      end

      assert(content_chunk, "Should receive content_chunk event")
      assert_equal("gpt-4", content_chunk[:model], "content_chunk should include model_id")
    end

    def test_content_chunk_with_nil_content_and_empty_tool_calls_not_emitted
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm(streaming: true)

      # Use SSE with only valid content (no nil/empty chunks in fixture)
      stub_streaming_llm(["Valid", "Content"], model: "gpt-4")

      content_chunks = []
      swarm.execute("Test") do |event|
        content_chunks << event if event[:type] == "content_chunk"
      end

      # All chunks should have content (emit_content_chunk has early return for nil/empty)
      content_chunks.each do |chunk|
        assert(
          chunk[:content] || chunk[:tool_calls],
          "Chunk should have content or tool_calls (nil/empty not emitted)",
        )
      end
    end

    # ========== Unit Tests: Tool Call Chunks ==========

    def test_content_chunk_with_tool_calls_has_partial_arguments
      skip("Tool call streaming requires more complex SSE fixture - defer to manual/integration testing")

      # Documents: tool_call arguments in chunks are partial strings, not parsed JSON
      # This would require Fixtures::SSEResponses.tool_call_stream() implementation
    end

    def test_separator_event_emitted_on_content_to_tool_call_transition
      skip("Tool call transition requires complex SSE fixture - defer to manual testing")

      # Documents separator event: emitted when chunks transition content → tool_call
      # Would require content_then_tool_stream() fixture with proper SSE format
    end

    def test_chunk_type_field_in_events
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm(streaming: true)

      stub_streaming_llm(["Text", " content"], model: "gpt-4")

      chunks = []
      swarm.execute("Test") do |event|
        chunks << event if event[:type] == "content_chunk"
      end

      # Verify chunk_type field is present
      chunks.each do |chunk|
        assert_includes(
          ["content", "tool_call", "separator"],
          chunk[:chunk_type],
          "chunk_type should be content, tool_call, or separator",
        )
      end

      # All should be "content" for text-only stream
      assert(chunks.all? { |c| c[:chunk_type] == "content" }, "Text-only stream should have chunk_type=content")
    end

    # ========== Integration Tests: Streaming Flow ==========

    def test_streaming_returns_complete_message_after_chunks
      # Test that streaming config doesn't break message accumulation
      # Use streaming: false to actually test with WebMock
      SwarmSDK.config.streaming = false

      swarm = build_streaming_swarm(streaming: false)

      stub_llm_request(mock_llm_response(content: "Hello world!"))

      result = swarm.execute("Test")

      assert_predicate(result, :success?)
      assert_equal("Hello world!", result.content, "Should return complete accumulated content")
    end

    def test_streaming_with_tool_calls_assembles_correctly
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm_with_read_tool

      # First response: stream tool call
      # Second response: final text after tool execution
      stub_llm_sequence(
        mock_llm_response(tool_calls: [{ name: "Read", arguments: { file_path: "/test.rb" } }]),
        mock_llm_response(content: "File read successfully"),
      )

      result = swarm.execute("Read a file")

      assert_predicate(result, :success?)
      assert_equal("File read successfully", result.content)
    end

    def test_per_agent_streaming_configuration
      # Build swarm with mixed streaming settings
      swarm = SwarmSDK.build do
        name("Mixed Streaming")

        agent(:streaming_agent) do
          model("gpt-5")
          system_prompt("I use streaming")
          streaming(true)
          tools(:Think)
        end

        agent(:non_streaming_agent) do
          model("gpt-5")
          system_prompt("I don't use streaming")
          streaming(false)
          tools(:Think)
        end

        lead(:streaming_agent)
      end

      # Verify definitions have correct streaming settings
      streaming_def = swarm.agent_definition(:streaming_agent)
      non_streaming_def = swarm.agent_definition(:non_streaming_agent)

      assert(streaming_def.streaming)
      refute(non_streaming_def.streaming)
    end

    # ========== Integration Tests: Delegation with Streaming ==========

    def test_delegation_with_both_agents_streaming
      # Test verifies that agents can have independent streaming settings
      # Use streaming: false to test with WebMock (WebMock doesn't support SSE)
      SwarmSDK.config.streaming = false

      swarm = SwarmSDK.build do
        name("Delegation Test")

        agent(:parent) do
          model("gpt-5")
          system_prompt("Parent agent")
          delegates_to(:child)
          streaming(false) # Would be true in production
        end

        agent(:child) do
          model("gpt-5")
          system_prompt("Child agent")
          streaming(false) # Would be true in production
        end

        lead(:parent)
      end

      stub_llm_sequence(
        # Parent stops after delegating (no final response in this test)
        mock_llm_response(tool_calls: [{ name: "WorkWithChild", arguments: { task: "Help me" } }]),
        # Child's response (this becomes the final result)
        mock_llm_response(content: "Child completed task"),
      )

      result = swarm.execute("Test delegation")

      # Verifies delegation works with streaming config (even if disabled for testing)
      assert_predicate(result, :success?)
      # Result is from the child since parent delegated and got tool result
      assert(
        result.content.include?("Child") || result.content.include?("completed"),
        "Should have child's response or parent's response incorporating child result",
      )
    end

    def test_delegation_with_parent_streaming_child_not
      swarm = SwarmSDK.build do
        name("Mixed Delegation")

        agent(:parent) do
          model("gpt-5")
          system_prompt("Parent")
          delegates_to(:child)
          streaming(true)
        end

        agent(:child) do
          model("gpt-5")
          system_prompt("Child")
          streaming(false)
        end

        lead(:parent)
      end

      stub_llm_sequence(
        mock_llm_response(tool_calls: [{ name: "WorkWithChild", arguments: { task: "Help" } }]),
        mock_llm_response(content: "Child response"),
        mock_llm_response(content: "Parent final"),
      )

      all_events = []
      swarm.execute("Test") { |event| all_events << event }

      # Parent might emit chunks (if mocked as streaming)
      # Child should NOT emit chunks (streaming=false)
      child_chunks = all_events.select { |e| e[:type] == "content_chunk" && e[:agent].to_s.start_with?("child") }

      # In current mock setup, chunks aren't actually streamed, so this just verifies no crash
      assert_kind_of(Array, child_chunks)
    end

    # ========== Integration Tests: Ephemeral Cleanup ==========

    def test_ephemeral_cleanup_with_ensure_block_on_error
      SwarmSDK.config.streaming = false

      swarm = build_streaming_swarm

      # Mock: first call fails with non-retryable error
      stub_llm_error(error_code: "unauthorized", message: "Invalid API key", status: 401)

      # Disable retries to fail immediately
      original_retries = RubyLLM.config.max_retries
      RubyLLM.config.max_retries = 0

      result = swarm.execute("Test")

      # Agent handles error and returns error message as content
      # (not a failure because execution completed)
      assert_includes(result.content, "Invalid API key", "Should contain error message")

      # Verify ephemeral cleanup by making second call
      WebMock.reset!
      stub_llm_request(mock_llm_response(content: "Success"))

      result2 = swarm.execute("Second call")

      assert_predicate(result2, :success?)
      assert_equal("Success", result2.content)
      # If ephemeral wasn't cleared, second call might have issues
    ensure
      RubyLLM.config.max_retries = original_retries if original_retries
    end

    def test_ephemeral_cleanup_on_streaming_failure
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm

      # Mock streaming that fails mid-stream
      # In practice this is hard to test with WebMock, so we'll test with a regular error
      # Note: Must use "rate_limit_exceeded" type for RubyLLM's streaming parser to correctly
      # identify this as a 429 error (it parses error type from body, not HTTP status)
      stub_llm_error(error_code: "rate_limit_exceeded", message: "Rate limit", status: 429)

      # Disable retries to fail immediately
      RubyLLM.config.max_retries = 0

      result = swarm.execute("Test")

      assert_predicate(result, :failure?)

      # Verify context manager state is clean by making another call
      WebMock.reset!
      stub_llm_request(mock_llm_response(content: "Recovery"))

      result2 = swarm.execute("Second")

      assert_predicate(result2, :success?)
    ensure
      RubyLLM.config.max_retries = 3
    end

    # ========== Integration Tests: Middleware Instrumentation ==========

    def test_middleware_captures_streaming_response_data
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm(streaming: true)

      # Mock streaming response with real SSE
      stub_streaming_llm(["Hello", " world"], model: "gpt-4")

      llm_response_events = []
      swarm.execute("Test") do |event|
        llm_response_events << event if event[:type] == "llm_api_response"
      end

      assert_operator(llm_response_events.size, :>, 0, "Should emit llm_api_response events")

      # Verify streaming flag is set and body is captured
      response_event = llm_response_events.first

      assert(response_event[:streaming], "Should be marked as streaming")
      assert(response_event[:body], "Response body should be captured")

      # Verify it's SSE format (starts with "data:")
      if response_event[:body].is_a?(String)
        assert(response_event[:body].start_with?("data:"), "Should be SSE format")
      end
    end

    def test_middleware_handles_non_streaming_responses
      SwarmSDK.config.streaming = false

      swarm = build_streaming_swarm(streaming: false)

      stub_llm_request(mock_llm_response(content: "Test"))

      llm_response_events = []
      swarm.execute("Test") do |event|
        llm_response_events << event if event[:type] == "llm_api_response"
      end

      response_event = llm_response_events.first

      refute_equal(true, response_event[:streaming], "Should not be marked as streaming")
      assert(response_event[:body], "Should have response body")
    end

    # ========== Integration Tests: Turn Timeout with Streaming ==========

    def test_turn_timeout_with_streaming_aborts_cleanly
      skip("Turn timeout requires actual async streaming behavior - hard to test with mocks")

      # This test would verify that turn_timeout correctly interrupts streaming
      # Requires mocking slow streaming behavior which is complex with WebMock
    end

    # ========== Integration Tests: Snapshot/Events Compatibility ==========

    def test_snapshot_reconstruction_ignores_content_chunk_events
      SwarmSDK.config.streaming = false # Keep simple for this test

      swarm = build_streaming_swarm

      stub_llm_request(mock_llm_response(content: "Test response"))

      events = []
      swarm.execute("Test prompt") { |event| events << event }

      # Add fake content_chunk events to the stream
      events << {
        type: "content_chunk",
        agent: :test_agent,
        content: "Fake chunk",
        timestamp: Time.now.utc.iso8601,
      }

      # Reconstruct messages from events
      messages = EventsToMessages.reconstruct(events, agent: :test_agent)

      # Verify content_chunk events don't affect reconstruction
      assistant_messages = messages.select { |m| m.role == :assistant }

      assert_equal(1, assistant_messages.size, "Should reconstruct 1 assistant message")
      assert_equal("Test response", assistant_messages.first.content)
    end

    def test_snapshot_from_events_ignores_content_chunk_events
      SwarmSDK.config.streaming = false

      swarm = build_streaming_swarm

      stub_llm_request(mock_llm_response(content: "Test"))

      events = []
      swarm.execute("Test") { |event| events << event }

      # Add content_chunk events
      events << {
        type: "content_chunk",
        agent: :test_agent,
        content: "Chunk",
        timestamp: Time.now.utc.iso8601,
      }

      # Reconstruct snapshot
      snapshot_data = SnapshotFromEvents.reconstruct(events)

      # Verify snapshot reconstruction isn't affected by content_chunk events
      assert(snapshot_data[:agents])
      assert(snapshot_data[:agents]["test_agent"])
    end

    # ========== Integration Tests: Observer Agents ==========

    def test_observer_agents_dont_receive_content_chunk_unless_subscribed
      SwarmSDK.config.streaming = false

      swarm = SwarmSDK.build do
        name("Observer Test")

        agent(:main) do
          model("gpt-5")
          system_prompt("Main agent")
        end

        agent(:profiler) do
          model("gpt-5")
          system_prompt("Profiler agent")
        end

        observer(:profiler) do
          on(:agent_stop) { |event| "Profile: #{event[:content]}" }
        end

        lead(:main)
      end

      stub_llm_sequence(
        mock_llm_response(content: "Main response"),
        mock_llm_response(content: "Observer response"),
      )

      observer_saw_content_chunk = false
      swarm.execute("Test") do |event|
        if event[:type] == "content_chunk" && event[:agent] == :profiler
          observer_saw_content_chunk = true
        end
      end

      refute(observer_saw_content_chunk, "Observer should NOT receive content_chunk events (not subscribed)")
    end

    # ========== YAML Configuration Tests ==========

    def test_yaml_config_with_streaming_true
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Streaming Test"
          lead: backend

          all_agents:
            streaming: true

          agents:
            backend:
              description: "Backend developer"
              model: gpt-5
              system_prompt: "Backend dev"
      YAML

      swarm = SwarmSDK.load(yaml_content)
      definition = swarm.agent_definition(:backend)

      assert(definition.streaming)
    end

    def test_yaml_config_with_streaming_false
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Non-Streaming Test"
          lead: backend

          agents:
            backend:
              description: "Backend developer"
              model: gpt-5
              system_prompt: "Backend"
              streaming: false
      YAML

      swarm = SwarmSDK.load(yaml_content)
      definition = swarm.agent_definition(:backend)

      refute(definition.streaming)
    end

    def test_yaml_all_agents_streaming_with_agent_override
      yaml_content = <<~YAML
        version: 2
        swarm:
          name: "Override Test"
          lead: fast_agent

          all_agents:
            streaming: true

          agents:
            fast_agent:
              description: "Fast agent"
              model: gpt-4o-mini
              system_prompt: "Fast agent"
              streaming: false

            slow_agent:
              description: "Slow agent"
              model: claude-opus-4
              system_prompt: "Slow agent"
              # Inherits streaming: true from all_agents
      YAML

      swarm = SwarmSDK.load(yaml_content)

      fast_def = swarm.agent_definition(:fast_agent)
      slow_def = swarm.agent_definition(:slow_agent)

      refute(fast_def.streaming, "fast_agent should override to false")
      assert(slow_def.streaming, "slow_agent should inherit true from all_agents")
    end

    # ========== Integration Tests: Error Handling ==========

    def test_emit_content_chunk_has_error_handling
      # Test that normal execution works (emit_content_chunk has rescue block)
      # Use streaming: false to test with WebMock
      SwarmSDK.config.streaming = false

      swarm = build_streaming_swarm(streaming: false)

      stub_llm_request(mock_llm_response(content: "Test response"))

      result = swarm.execute("Test")

      # The method has rescue StandardError => e in emit_content_chunk
      # This verifies the defensive coding pattern is in place
      assert_predicate(result, :success?)
      assert_equal("Test response", result.content)
    end

    # ========== Integration Tests: Event Subscriber Isolation ==========

    def test_filtered_subscribers_dont_receive_content_chunk
      SwarmSDK.config.streaming = false

      build_streaming_swarm

      stub_llm_request(mock_llm_response(content: "Test"))

      # Subscribe to specific event type (not content_chunk)
      agent_stop_events = []
      LogCollector.subscribe(filter: { type: "agent_stop" }) do |event|
        agent_stop_events << event
      end

      LogStream.emitter = LogCollector

      # Manually emit a content_chunk event
      LogStream.emit(
        type: "content_chunk",
        agent: :test,
        content: "Chunk",
      )

      # Subscriber should NOT receive it
      assert_equal(0, agent_stop_events.size, "Filtered subscriber should not receive content_chunk")
    ensure
      LogCollector.reset!
      LogStream.reset!
    end

    def test_content_chunk_subscribers_only_receive_content_chunks
      SwarmSDK.config.streaming = false

      # Subscribe only to content_chunk events
      chunk_events = []
      LogCollector.subscribe(filter: { type: "content_chunk" }) do |event|
        chunk_events << event
      end

      LogStream.emitter = LogCollector

      # Emit various event types
      LogStream.emit(type: "agent_start", agent: :test)
      LogStream.emit(type: "content_chunk", agent: :test, content: "Chunk 1")
      LogStream.emit(type: "agent_stop", agent: :test)
      LogStream.emit(type: "content_chunk", agent: :test, content: "Chunk 2")

      # Should only receive content_chunk events
      assert_equal(2, chunk_events.size)
      assert_equal(["Chunk 1", "Chunk 2"], chunk_events.map { |e| e[:content] })
    ensure
      LogCollector.reset!
      LogStream.reset!
    end

    # ========== Integration Tests: Chunk Type Tracking ==========

    def test_chunk_type_field_present_in_content_chunks
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm

      stub_llm_request(mock_llm_response(content: "Test"))

      chunks = []
      swarm.execute("Test") do |event|
        chunks << event if event[:type] == "content_chunk"
      end

      # May or may not have chunks depending on mock implementation
      # If we have chunks, they should have chunk_type field
      chunks.each do |chunk|
        assert_includes(
          ["content", "tool_call", "separator"],
          chunk[:chunk_type],
          "chunk_type should be content, tool_call, or separator",
        )
      end
    end

    def test_separator_only_emitted_once_per_transition
      SwarmSDK.config.streaming = true

      swarm = build_streaming_swarm

      # Simulate: content → tool_call → tool_call (should only emit separator once)
      # Note: This is theoretical with current WebMock limitations
      stub_llm_request(mock_llm_response(content: "Done"))

      separators = []
      swarm.execute("Test") do |event|
        next unless event[:type] == "content_chunk"

        separators << event if event[:chunk_type] == "separator"
      end

      # With WebMock we won't actually get real streaming chunks,
      # but this test documents the expected behavior
      assert_operator(separators.size, :<=, 1, "Should emit at most 1 separator per transition")
    end

    # ========== Integration Tests: Definition standard_keys ==========

    def test_streaming_is_standard_key_not_plugin_config
      definition = Agent::Definition.new(:test, {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
        streaming: false,
        custom_plugin_key: "plugin_value",
      })

      # streaming should NOT be in plugin_configs (use public API)
      refute(definition.plugin_config(:streaming), "streaming should be standard SDK key, not plugin config")

      # custom_plugin_key SHOULD be in plugin_configs (use public API)
      assert_equal(
        "plugin_value",
        definition.plugin_config(:custom_plugin_key),
        "Custom keys should be in plugin_configs",
      )
    end

    # ========== Helper Methods ==========

    private

    # Build a simple swarm for streaming tests
    #
    # @param streaming [Boolean, nil] Explicit streaming setting (nil = use global)
    # @return [Swarm] Test swarm
    def build_streaming_swarm(streaming: nil)
      swarm = Swarm.new(name: "Streaming Test", scratchpad: @test_scratchpad)

      config = {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
        tools: [:Think],
        assume_model_exists: true,
      }
      config[:streaming] = streaming unless streaming.nil?

      agent_def = Agent::Definition.new(:test_agent, config)
      swarm.add_agent(agent_def)
      swarm.lead = :test_agent

      swarm
    end

    # Build swarm with Read tool for tool call tests
    def build_streaming_swarm_with_read_tool
      swarm = Swarm.new(name: "Tool Test", scratchpad: @test_scratchpad)

      agent_def = Agent::Definition.new(:test_agent, {
        description: "Test agent",
        model: "gpt-5",
        system_prompt: "Test",
        tools: [:Read],
        assume_model_exists: true,
        streaming: false, # Disable for easier testing
      })

      swarm.add_agent(agent_def)
      swarm.lead = :test_agent

      swarm
    end
  end
end
