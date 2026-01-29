# frozen_string_literal: true

# Adds concurrent tool execution support to RubyLLM::Chat
# Supports :async and :threads executors with configurable concurrency limits
#
# Fork Reference: Commit d0912c7, file lib/ruby_llm/tool_executors.rb

module RubyLLM
  # Tool executor registry
  class << self
    def tool_executors
      @tool_executors ||= {}
    end

    def register_tool_executor(name, &block)
      tool_executors[name] = block
    end

    def get_tool_executor(name)
      tool_executors[name] || raise(ArgumentError, "Unknown tool executor: #{name}")
    end
  end

  # Built-in tool executors
  module ToolExecutors
    class << self
      def register_defaults
        register_threads_executor
        register_async_executor
      end

      private

      def register_threads_executor
        RubyLLM.register_tool_executor(:threads) do |tool_calls, max_concurrency:, &execute|
          results = {}
          mutex = Mutex.new
          semaphore = max_concurrency ? Thread::SizedQueue.new(max_concurrency) : nil

          # Fill semaphore with permits
          max_concurrency&.times { semaphore << :permit }

          threads = tool_calls.map do |tool_call|
            Thread.new do
              permit = semaphore&.pop

              begin
                result = execute.call(tool_call)
                mutex.synchronize { results[tool_call.id] = result }
              rescue StandardError => e
                error_result = "Error: #{e.class}: #{e.message}"
                mutex.synchronize { results[tool_call.id] = error_result }
                RubyLLM.logger.warn("[RubyLLM] Tool #{tool_call.id} failed: #{e.message}")
              ensure
                semaphore&.push(permit) if permit
              end
            end
          end

          threads.each(&:join)
          results
        end
      end

      def register_async_executor
        RubyLLM.register_tool_executor(:async) do |tool_calls, max_concurrency:, &execute|
          AsyncExecutor.execute(tool_calls, max_concurrency: max_concurrency, &execute)
        end
      end
    end

    module AsyncExecutor
      class << self
        def execute(tool_calls, max_concurrency:, &block)
          load_async_gem
          run_with_sync { execute_tools(tool_calls, max_concurrency, &block) }
        end

        private

        def load_async_gem
          require "async"
          require "async/barrier"
          require "async/semaphore"
        rescue LoadError => e
          raise LoadError,
            "The async gem is required for :async tool executor. " \
              "Add `gem 'async'` to your Gemfile. Original error: #{e.message}"
        end

        def run_with_sync(&block)
          if Async::Task.current?
            # Already inside an async reactor (SwarmSDK always runs in one).
            # Just yield — no Sync, no nested reactor, no Promise mutex issues.
            yield
          else
            # Outside async context (e.g., standalone RubyLLM usage).
            # Sync handles reactor creation and cleanup.
            Sync(&block)
          end
        end

        def execute_tools(tool_calls, max_concurrency)
          semaphore = max_concurrency ? Async::Semaphore.new(max_concurrency) : nil
          barrier = Async::Barrier.new
          results = {}

          tool_calls.each do |tool_call|
            barrier.async do
              results[tool_call.id] = execute_single_tool(tool_call, semaphore) { yield tool_call }
            rescue StandardError => e
              results[tool_call.id] = "Error: #{e.class}: #{e.message}"
              RubyLLM.logger.warn("[RubyLLM] Tool #{tool_call.id} failed: #{e.message}")
            end
          end

          barrier.wait
          results
        end

        def execute_single_tool(_tool_call, semaphore, &)
          if semaphore
            semaphore.acquire(&)
          else
            yield
          end
        end
      end
    end
  end

  class Chat
    attr_reader :tool_concurrency, :max_concurrency

    # Module to prepend for concurrent tool execution
    module ConcurrentToolExecution
      def initialize(tool_concurrency: nil, max_concurrency: nil, **kwargs)
        @tool_concurrency = tool_concurrency
        @max_concurrency = max_concurrency
        super(**kwargs)
      end

      # Configure tool concurrency
      def with_tool_concurrency(executor, max: nil)
        @tool_concurrency = executor
        @max_concurrency = max
        self
      end

      private

      # Override handle_tool_calls to support concurrent execution
      # This method is called when tool_concurrency is set
      def handle_tool_calls(response, &block)
        return super unless @tool_concurrency

        tool_calls = response.tool_calls
        halt_result = execute_tools_concurrently(tool_calls)
        halt_result || complete(&block)
      end

      def execute_tools_concurrently(tool_calls)
        executor = RubyLLM.get_tool_executor(@tool_concurrency)
        tool_calls_array = tool_calls.values

        # Execute tools concurrently, emitting events per-tool
        results = executor.call(tool_calls_array, max_concurrency: @max_concurrency) do |tool_call|
          execute_single_tool_with_events(tool_call)
        end

        # Add all tool result messages atomically
        add_tool_results_atomically(tool_calls, results)

        # Find first halt result by original order
        find_first_halt(tool_calls, results)
      end

      # Execute a single tool with events (for concurrent execution)
      # Emits new_message, tool_call, and tool_result events per-tool
      def execute_single_tool_with_events(tool_call)
        emit(:new_message)
        emit(:tool_call, tool_call)
        result = execute_tool_with_hook(tool_call)
        emit(:tool_result, tool_call, result)
        result
      end

      # Add all tool result messages atomically to ensure consistent state
      def add_tool_results_atomically(tool_calls, results)
        messages = []

        tool_calls.each_key do |id|
          tool_call = tool_calls[id]
          result = results[id]

          tool_payload = result.is_a?(Tool::Halt) ? result.content : result
          content = content_like?(tool_payload) ? tool_payload : tool_payload.to_s
          message = add_message(role: :tool, content: content, tool_call_id: tool_call.id)
          messages << message
        end

        # Fire end_message events for all messages
        messages.each { |msg| emit(:end_message, msg) }
      end

      # Find the first halt result by request order
      def find_first_halt(tool_calls, results)
        tool_calls.each_key do |id|
          result = results[id]
          return result if result.is_a?(Tool::Halt)
        end
        nil
      end
    end

    # Prepend after MultiSubscriberCallbacks so we can call its methods
    prepend ConcurrentToolExecution
  end
end

# Register built-in executors
RubyLLM::ToolExecutors.register_defaults
