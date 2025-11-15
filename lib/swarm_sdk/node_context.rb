# frozen_string_literal: true

module SwarmSDK
  # NodeContext provides context information to node transformers
  #
  # This class is passed to input and output transformers, giving them access to:
  # - The original user prompt
  # - Results from all previous nodes
  # - Current node metadata
  # - Convenience accessors for common operations
  #
  # @example Input transformer
  #   input do |ctx|
  #     ctx.content              # Previous node's content (convenience)
  #     ctx.original_prompt      # Original user prompt
  #     ctx.all_results[:plan]   # Access any previous node
  #     ctx.node_name            # Current node name
  #   end
  #
  # @example Output transformer
  #   output do |ctx|
  #     ctx.content              # Current result's content (convenience)
  #     ctx.original_prompt      # Original user prompt
  #     ctx.all_results[:plan]   # Access previous nodes
  #   end
  class NodeContext
    attr_reader :original_prompt, :all_results, :node_name, :dependencies

    # For input transformers: result from previous node(s)
    attr_reader :previous_result

    # For output transformers: current node's result
    attr_reader :result

    class << self
      # Create a NodeContext for input transformers
      #
      # @param previous_result [Result, Hash, String] Previous node's result or hash of results
      # @param all_results [Hash<Symbol, Result>] Results from all completed nodes
      # @param original_prompt [String] The original user prompt
      # @param node_name [Symbol] Current node name
      # @param dependencies [Array<Symbol>] Node dependencies
      # @param transformed_content [String, nil] Already-transformed content from previous output transformer
      # @return [NodeContext]
      def for_input(previous_result:, all_results:, original_prompt:, node_name:, dependencies:, transformed_content: nil)
        new(
          previous_result: previous_result,
          all_results: all_results,
          original_prompt: original_prompt,
          node_name: node_name,
          dependencies: dependencies,
          result: nil,
          transformed_content: transformed_content,
        )
      end

      # Create a NodeContext for output transformers
      #
      # @param result [Result] Current node's execution result
      # @param all_results [Hash<Symbol, Result>] Results from all completed nodes (including current)
      # @param original_prompt [String] The original user prompt
      # @param node_name [Symbol] Current node name
      # @return [NodeContext]
      def for_output(result:, all_results:, original_prompt:, node_name:)
        new(
          result: result,
          all_results: all_results,
          original_prompt: original_prompt,
          node_name: node_name,
          dependencies: [],
          previous_result: nil,
          transformed_content: nil,
        )
      end
    end

    def initialize(previous_result:, all_results:, original_prompt:, node_name:, dependencies:, result:, transformed_content:)
      @previous_result = previous_result
      @result = result
      @all_results = all_results
      @original_prompt = original_prompt
      @node_name = node_name
      @dependencies = dependencies
      @transformed_content = transformed_content
    end

    # Convenience accessor: Get content from previous_result or result
    #
    # For input transformers:
    #   - Returns transformed_content if available (from previous output transformer)
    #   - Otherwise returns previous_result.content (original content)
    #   - Returns nil for multiple dependencies (use all_results instead)
    # For output transformers: returns result.content
    #
    # @return [String, nil]
    def content
      if @result
        # Output transformer context: return current result's content
        @result.content
      elsif @transformed_content
        # Input transformer with transformed content from previous output
        @transformed_content
      elsif @previous_result.respond_to?(:content)
        # Input transformer context with Result object (original content)
        @previous_result.content
      elsif @previous_result.is_a?(Hash)
        # Input transformer with multiple dependencies (hash of results)
        nil # No single "content" - user must pick from all_results hash
      else
        # String or other type (initial prompt, no dependencies)
        @previous_result.to_s
      end
    end

    # Convenience accessor: Get agent from previous_result or result
    #
    # @return [String, nil]
    def agent
      if @result
        @result.agent
      elsif @previous_result.respond_to?(:agent)
        @previous_result.agent
      end
    end

    # Convenience accessor: Get logs from previous_result or result
    #
    # @return [Array, nil]
    def logs
      if @result
        @result.logs
      elsif @previous_result.respond_to?(:logs)
        @previous_result.logs
      end
    end

    # Convenience accessor: Get duration from previous_result or result
    #
    # @return [Float, nil]
    def duration
      if @result
        @result.duration
      elsif @previous_result.respond_to?(:duration)
        @previous_result.duration
      end
    end

    # Convenience accessor: Get error from previous_result or result
    #
    # @return [Exception, nil]
    def error
      if @result
        @result.error
      elsif @previous_result.respond_to?(:error)
        @previous_result.error
      end
    end

    # Convenience accessor: Check success status
    #
    # @return [Boolean, nil]
    def success?
      if @result
        @result.success?
      elsif @previous_result.respond_to?(:success?)
        @previous_result.success?
      end
    end

    # Control flow methods for transformers
    # These return special hashes that Workflow recognizes

    # Skip current node's LLM execution and return content immediately
    #
    # Only valid for input transformers.
    #
    # @param content [String] Content to return (skips LLM call)
    # @return [Hash] Control hash for skip_execution
    # @raise [ArgumentError] If content is nil
    #
    # @example
    #   input do |ctx|
    #     cached = check_cache(ctx.content)
    #     return ctx.skip_execution(content: cached) if cached
    #     ctx.content
    #   end
    def skip_execution(content:)
      if content.nil?
        raise ArgumentError,
          "skip_execution requires content (got nil). " \
            "Check that ctx.content or your content source is not nil. " \
            "Node: #{@node_name}"
      end
      { skip_execution: true, content: content }
    end

    # Halt entire workflow and return content as final result
    #
    # Valid for both input and output transformers.
    #
    # @param content [String] Final content to return
    # @return [Hash] Control hash for halt_workflow
    # @raise [ArgumentError] If content is nil
    #
    # @example
    #   output do |ctx|
    #     return ctx.halt_workflow(content: ctx.content) if converged?(ctx.content)
    #     ctx.content
    #   end
    def halt_workflow(content:)
      if content.nil?
        raise ArgumentError,
          "halt_workflow requires content (got nil). " \
            "Check that ctx.content or your content source is not nil. " \
            "Node: #{@node_name}"
      end
      { halt_workflow: true, content: content }
    end

    # Jump to a different node with provided content as input
    #
    # Valid for both input and output transformers.
    #
    # @param node [Symbol] Node name to jump to
    # @param content [String] Content to pass to target node
    # @return [Hash] Control hash for goto_node
    # @raise [ArgumentError] If content is nil
    #
    # @example
    #   input do |ctx|
    #     return ctx.goto_node(:review, content: ctx.content) if needs_review?(ctx.content)
    #     ctx.content
    #   end
    def goto_node(node, content:)
      if content.nil?
        raise ArgumentError,
          "goto_node requires content (got nil). " \
            "Check that ctx.content or your content source is not nil. " \
            "This often happens when the previous node failed with an error. " \
            "Node: #{@node_name}, Target: #{node}"
      end
      { goto_node: node.to_sym, content: content }
    end
  end
end
