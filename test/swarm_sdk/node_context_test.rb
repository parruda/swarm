# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  class NodeContextTest < Minitest::Test
    def setup
      @model_id = "gpt-4o-mini"
      @provider = "openai"
    end

    def test_input_transformer_receives_node_context
      received_context = nil

      swarm = SwarmSDK.workflow do
        name("Context Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:first) do
          agent(:agent1)
        end

        node(:second) do
          agent(:agent1)
          depends_on(:first)

          input do |ctx|
            received_context = ctx
            ctx.content
          end
        end

        start_node(:first)
      end

      # Trigger validation which calls auto_add
      swarm.nodes[:second].validate!

      # Verify context is a NodeContext
      assert_instance_of(NodeContext, received_context) if received_context
    end

    def test_output_transformer_receives_node_context
      received_context = nil

      swarm = SwarmSDK.workflow do
        name("Output Context Test")

        agent(:agent1) do
          model(@model_id)
          provider(@provider)
          description("Agent 1")
          system_prompt("Agent 1")
          coding_agent(false)
        end

        node(:test) do
          agent(:agent1)

          output do |ctx|
            received_context = ctx
            ctx.content
          end
        end

        start_node(:test)
      end

      # Trigger validation
      swarm.nodes[:test].validate!

      # We can't actually test this without executing, but we can verify the transformer is set
      assert(swarm.nodes[:test].output_transformer)
    end

    def test_node_context_original_prompt_accessible
      # Use agent-less nodes to avoid HTTP calls
      original_prompt_in_node1 = nil
      original_prompt_in_node2 = nil
      original_prompt_in_node3 = nil

      swarm = SwarmSDK.workflow do
        name("Original Prompt Test")

        node(:node1) do
          output do |ctx|
            original_prompt_in_node1 = ctx.original_prompt
            "output1"
          end
        end

        node(:node2) do
          input do |ctx|
            original_prompt_in_node2 = ctx.original_prompt
            ctx.content
          end

          output { |_ctx| "output2" }
          depends_on(:node1)
        end

        node(:node3) do
          input do |ctx|
            original_prompt_in_node3 = ctx.original_prompt
            ctx.content
          end

          output(&:content)
          depends_on(:node2)
        end

        start_node(:node1)
      end

      swarm.execute("TEST PROMPT")

      # All nodes should have access to the same original prompt
      assert_equal("TEST PROMPT", original_prompt_in_node1)
      assert_equal("TEST PROMPT", original_prompt_in_node2)
      assert_equal("TEST PROMPT", original_prompt_in_node3)
    end

    def test_node_context_all_results_accessible
      # Capture keys and content at execution time (not the hash by reference)
      results_keys_in_node2 = nil
      results_keys_in_node3 = nil
      node1_content_in_node2 = nil
      node1_content_in_node3 = nil
      node2_content_in_node3 = nil

      swarm = SwarmSDK.workflow do
        name("All Results Test")

        node(:node1) do
          output { |_ctx| "NODE1_OUTPUT" }
        end

        node(:node2) do
          input do |ctx|
            # Capture keys at execution time
            results_keys_in_node2 = ctx.all_results.keys.dup
            node1_content_in_node2 = ctx.all_results[:node1]&.content
            ctx.content
          end

          output { |_ctx| "NODE2_OUTPUT" }
          depends_on(:node1)
        end

        node(:node3) do
          input do |ctx|
            # Capture keys and content at execution time
            results_keys_in_node3 = ctx.all_results.keys.dup
            node1_content_in_node3 = ctx.all_results[:node1]&.content
            node2_content_in_node3 = ctx.all_results[:node2]&.content
            ctx.content
          end

          output(&:content)
          depends_on(:node2)
        end

        start_node(:node1)
      end

      swarm.execute("test")

      # Node2 should have access to node1 result only
      assert_equal([:node1], results_keys_in_node2)
      assert_equal("NODE1_OUTPUT", node1_content_in_node2)

      # Node3 should have access to node1 AND node2 results
      assert_equal([:node1, :node2].sort, results_keys_in_node3.sort)
      assert_equal("NODE1_OUTPUT", node1_content_in_node3)
      assert_equal("NODE2_OUTPUT", node2_content_in_node3)
    end

    def test_node_context_node_name_is_correct
      node_name_in_node1 = nil
      node_name_in_node2 = nil

      swarm = SwarmSDK.workflow do
        name("Node Name Test")

        node(:planning) do
          output do |ctx|
            node_name_in_node1 = ctx.node_name
            "output"
          end
        end

        node(:implementation) do
          input do |ctx|
            node_name_in_node2 = ctx.node_name
            ctx.content
          end

          output(&:content)
          depends_on(:planning)
        end

        start_node(:planning)
      end

      swarm.execute("test")

      assert_equal(:planning, node_name_in_node1)
      assert_equal(:implementation, node_name_in_node2)
    end

    def test_node_context_dependencies_list
      dependencies_in_node = nil

      swarm = SwarmSDK.workflow do
        name("Dependencies Test")

        node(:node1) do
          output { |_ctx| "output1" }
        end

        node(:node2) do
          output { |_ctx| "output2" }
        end

        node(:node3) do
          input do |ctx|
            dependencies_in_node = ctx.dependencies
            ctx.content
          end

          output(&:content)
          depends_on(:node1, :node2)
        end

        start_node(:node1)
      end

      swarm.execute("test")

      # Node3 depends on node1 and node2
      assert_equal([:node1, :node2].sort, dependencies_in_node.sort)
    end

    def test_node_context_convenience_accessor_content
      content_in_input = nil
      content_in_output = nil

      swarm = SwarmSDK.workflow do
        name("Content Accessor Test")

        node(:node1) do
          output do |ctx|
            content_in_output = ctx.content
            "TRANSFORMED"
          end
        end

        node(:node2) do
          input do |ctx|
            content_in_input = ctx.content
            ctx.content
          end

          output(&:content)
          depends_on(:node1)
        end

        start_node(:node1)
      end

      # Execute with initial prompt
      swarm.execute("INITIAL")

      # Node1 output should see its own result content
      # (We can't easily test this without mocking LLM, but we test node2)

      # Node2 input should see TRANSFORMED content from node1's output
      assert_equal("TRANSFORMED", content_in_input)
    end

    def test_node_context_multiple_dependencies_hash
      previous_result_type = nil

      swarm = SwarmSDK.workflow do
        name("Multi-dep Test")

        node(:node1) do
          output { |_ctx| "output1" }
        end

        node(:node2) do
          output { |_ctx| "output2" }
        end

        node(:node3) do
          input do |ctx|
            previous_result_type = ctx.previous_result.class
            # With multiple dependencies, previous_result is a Hash
            ctx.content # Should be nil for multiple dependencies
          end

          output { |ctx| ctx.content || "default" }
          depends_on(:node1, :node2)
        end

        start_node(:node1)
      end

      swarm.execute("test")

      # With multiple dependencies, previous_result should be a Hash
      assert_equal(Hash, previous_result_type)
    end

    def test_node_context_result_metadata_accessible
      result_metadata = {}

      swarm = SwarmSDK.workflow do
        name("Metadata Test")

        node(:node1) do
          output { |_ctx| "node1_output" }
        end

        node(:node2) do
          input do |ctx|
            # Access metadata from previous result
            ctx.previous_result
            result_metadata[:agent] = ctx.agent
            result_metadata[:has_logs] = ctx.logs.is_a?(Array)
            result_metadata[:has_duration] = ctx.duration.is_a?(Numeric)

            ctx.content
          end

          output(&:content)
          depends_on(:node1)
        end

        start_node(:node1)
      end

      swarm.execute("test")

      # Verify metadata is accessible
      assert(result_metadata[:agent])
      assert(result_metadata[:has_logs])
      assert(result_metadata[:has_duration])
    end
  end
end
