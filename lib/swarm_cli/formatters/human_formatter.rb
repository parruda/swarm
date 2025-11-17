# frozen_string_literal: true

module SwarmCLI
  module Formatters
    # HumanFormatter creates beautiful, detailed real-time output using reusable UI components.
    # Shows everything: agent thinking, tool calls with arguments, results, responses.
    # Uses clean component architecture for maintainability and testability.
    #
    # Modes:
    # - :non_interactive - Full headers, task prompt, complete summary (for single execution)
    # - :interactive - Minimal output for REPL (headers shown in welcome screen)
    class HumanFormatter
      attr_reader :spinner_manager

      def initialize(output: $stdout, quiet: false, truncate: false, verbose: false, mode: :non_interactive)
        @output = output
        @quiet = quiet
        @truncate = truncate
        @verbose = verbose
        @mode = mode

        # Initialize Pastel with TTY detection
        @pastel = Pastel.new(enabled: output.tty?)

        # Initialize state managers
        @color_cache = SwarmCLI::UI::State::AgentColorCache.new
        @depth_tracker = SwarmCLI::UI::State::DepthTracker.new
        @usage_tracker = SwarmCLI::UI::State::UsageTracker.new
        @spinner_manager = SwarmCLI::UI::State::SpinnerManager.new

        # Initialize components
        @divider = SwarmCLI::UI::Components::Divider.new(pastel: @pastel, terminal_width: TTY::Screen.width)
        @agent_badge = SwarmCLI::UI::Components::AgentBadge.new(pastel: @pastel, color_cache: @color_cache)
        @content_block = SwarmCLI::UI::Components::ContentBlock.new(pastel: @pastel)
        @panel = SwarmCLI::UI::Components::Panel.new(pastel: @pastel)

        # Initialize event renderer
        @event_renderer = SwarmCLI::UI::Renderers::EventRenderer.new(
          pastel: @pastel,
          agent_badge: @agent_badge,
          depth_tracker: @depth_tracker,
        )

        # Track last context percentage for warnings
        @last_context_percentage = {}

        # Start time tracking
        @start_time = nil
      end

      # Called when swarm execution starts
      def on_start(config_path:, swarm_name:, lead_agent:, prompt:)
        @start_time = Time.now

        # Only show headers in non-interactive mode
        if @mode == :non_interactive
          print_header(swarm_name, lead_agent)
          print_prompt(prompt)
          @output.puts @divider.full
          @output.puts @pastel.bold("#{SwarmCLI::UI::Icons::INFO} Execution Log:")
          @output.puts
        end
      end

      # Called for each log entry from SwarmSDK
      def on_log(entry)
        return if @quiet

        case entry[:type]
        when "user_prompt"
          handle_user_request(entry)
        when "agent_step"
          handle_agent_step(entry)
        when "agent_stop"
          handle_agent_stop(entry)
        when "tool_call"
          handle_tool_call(entry)
        when "tool_result"
          handle_tool_result(entry)
        when "agent_delegation"
          handle_agent_delegation(entry)
        when "delegation_result"
          handle_delegation_result(entry)
        when "context_limit_warning"
          handle_context_warning(entry)
        when "model_lookup_warning"
          handle_model_lookup_warning(entry)
        when "compression_started"
          handle_compression_started(entry)
        when "compression_completed"
          handle_compression_completed(entry)
        when "hook_executed"
          handle_hook_executed(entry)
        when "breakpoint_enter"
          handle_breakpoint_enter(entry)
        when "breakpoint_exit"
          handle_breakpoint_exit(entry)
        when "llm_retry_attempt"
          handle_llm_retry_attempt(entry)
        when "llm_retry_exhausted"
          handle_llm_retry_exhausted(entry)
        end
      end

      # Called when swarm execution completes successfully
      def on_success(result:)
        # Defensive: ensure all spinners are stopped before showing result
        @spinner_manager.stop_all

        if @mode == :non_interactive
          # Full result display with summary
          @output.puts
          @output.puts @divider.full
        end

        # Print result (handles mode internally)
        print_result(result)

        # Only print summary in non-interactive mode
        print_summary(result) if @mode == :non_interactive
      end

      # Called when swarm execution fails
      def on_error(error:, duration: nil)
        # Defensive: ensure all spinners are stopped before showing error
        @spinner_manager.stop_all

        @output.puts
        @output.puts @divider.full
        print_error(error)
        @output.puts @divider.full
      end

      private

      def handle_user_request(entry)
        agent = entry[:agent]
        @usage_tracker.track_agent(agent)
        @usage_tracker.track_llm_request(entry[:usage])

        # Stop any delegation waiting spinner (in case this agent was delegated to)
        unless @quiet
          delegation_spinner = "delegation_#{agent}".to_sym
          @spinner_manager.stop(delegation_spinner) if @spinner_manager.active?(delegation_spinner)
        end

        # Render agent thinking line
        @output.puts @event_renderer.agent_thinking(
          agent: agent,
          model: entry[:model],
          timestamp: entry[:timestamp],
        )

        # Show tools available
        if entry[:tools]&.any?
          @output.puts @event_renderer.tools_available(entry[:tools], indent: @depth_tracker.get(agent))
        end

        # Show delegation options
        if entry[:delegates_to]&.any?
          @output.puts @event_renderer.delegates_to(
            entry[:delegates_to],
            indent: @depth_tracker.get(agent),
            color_cache: @color_cache,
          )
        end

        @output.puts

        # Start spinner for agent thinking
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          @spinner_manager.start(spinner_key, "#{agent} is thinking...")
        end
      end

      def handle_agent_step(entry)
        agent = entry[:agent]
        indent_level = @depth_tracker.get(agent)

        # Stop agent thinking spinner
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          @spinner_manager.stop(spinner_key)
        end

        # Track usage
        if entry[:usage]
          @usage_tracker.track_llm_request(entry[:usage])
          @last_context_percentage[agent] = entry[:usage][:tokens_used_percentage]

          # Render usage stats
          @output.puts @event_renderer.usage_stats(
            tokens: entry[:usage][:total_tokens] || 0,
            cost: entry[:usage][:total_cost] || 0.0,
            context_pct: entry[:usage][:tokens_used_percentage],
            remaining: entry[:usage][:tokens_remaining],
            cumulative: entry[:usage][:cumulative_total_tokens],
            indent: indent_level,
          )
        end

        # Display thinking text (if present)
        if entry[:content] && !entry[:content].empty?
          thinking = @event_renderer.thinking_text(entry[:content], indent: indent_level)
          @output.puts thinking unless thinking.empty?
          @output.puts if thinking && !thinking.empty?
        end

        # Show tool request summary
        tool_count = entry[:tool_calls]&.size || 0
        if tool_count > 0
          indent = @depth_tracker.indent(agent)
          @output.puts "#{indent}  #{@pastel.dim("→ Requesting #{tool_count} tool#{"s" if tool_count > 1}...")}"
        end

        @output.puts
        @output.puts @divider.event(indent: indent_level)
      end

      def handle_agent_stop(entry)
        agent = entry[:agent]
        indent_level = @depth_tracker.get(agent)

        # Stop agent thinking spinner with success
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          @spinner_manager.success(spinner_key, "completed")
        end

        # Track usage
        if entry[:usage]
          @usage_tracker.track_llm_request(entry[:usage])
          @last_context_percentage[agent] = entry[:usage][:tokens_used_percentage]

          # Render usage stats
          @output.puts @event_renderer.usage_stats(
            tokens: entry[:usage][:total_tokens] || 0,
            cost: entry[:usage][:total_cost] || 0.0,
            context_pct: entry[:usage][:tokens_used_percentage],
            remaining: entry[:usage][:tokens_remaining],
            cumulative: entry[:usage][:cumulative_total_tokens],
            indent: indent_level,
          )
        end

        # Display final response (only for top-level agent in non-interactive mode)
        # In interactive mode, response is shown by print_result to avoid duplication
        if entry[:content] && !entry[:content].empty? && indent_level.zero? && @mode == :non_interactive
          @output.puts @event_renderer.agent_response(
            agent: agent,
            timestamp: entry[:timestamp],
          )

          # Render response content
          indent = @depth_tracker.indent(agent)
          response_lines = entry[:content].split("\n")

          if @truncate && response_lines.length > 12
            response_lines.first(12).each { |line| @output.puts "#{indent}  #{line}" }
            @output.puts "#{indent}  #{@pastel.dim("... (#{response_lines.length - 12} more lines)")}"
          else
            response_lines.each { |line| @output.puts "#{indent}  #{line}" }
          end
        end

        @output.puts
        @output.puts @event_renderer.agent_completed(agent: agent)
        @output.puts
        @output.puts @divider.event(indent: indent_level)
      end

      def handle_tool_call(entry)
        agent = entry[:agent]
        @usage_tracker.track_tool_call(tool_call_id: entry[:tool_call_id], tool_name: entry[:tool])

        # Special handling for Think tool - show as thoughts, not as a tool call
        if entry[:tool] == "Think" && entry[:arguments] && entry[:arguments]["thoughts"]
          thoughts = entry[:arguments]["thoughts"]
          thinking = @event_renderer.thinking_text(thoughts, indent: @depth_tracker.get(agent))
          @output.puts thinking unless thinking.empty?
          @output.puts
          # Don't show spinner for Think tool
          return
        end

        # Render tool call event
        @output.puts @event_renderer.tool_call(
          agent: agent,
          tool: entry[:tool],
          timestamp: entry[:timestamp],
        )

        # Show arguments (skip TodoWrite unless verbose)
        args = entry[:arguments]
        show_args = args && !args.empty?
        show_args &&= entry[:tool] != "TodoWrite" || @verbose

        if show_args
          @output.puts @event_renderer.tool_arguments(
            args,
            indent: @depth_tracker.get(agent),
            truncate: @truncate,
          )
        end

        @output.puts

        # Start spinner for tool execution
        unless @quiet || entry[:tool] == "TodoWrite"
          spinner_key = "tool_#{entry[:tool_call_id]}".to_sym
          @spinner_manager.start(spinner_key, "Executing #{entry[:tool]}...")
        end
      end

      def handle_tool_result(entry)
        agent = entry[:agent]
        tool_name = entry[:tool] || @usage_tracker.tool_name_for(entry[:tool_call_id])

        # Special handling for Think tool - skip showing result (already shown as thoughts)
        if tool_name == "Think"
          # Don't show anything - thoughts were already displayed in handle_tool_call
          # Start spinner for agent processing
          unless @quiet
            spinner_key = "agent_#{agent}".to_sym
            indent = @depth_tracker.indent(agent)
            @spinner_manager.start(spinner_key, "#{indent}#{agent} is processing...")
          end
          return
        end

        # Stop tool spinner with success
        unless @quiet || tool_name == "TodoWrite"
          spinner_key = "tool_#{entry[:tool_call_id]}".to_sym
          @spinner_manager.success(spinner_key, "completed")
        end

        # Special handling for TodoWrite
        if tool_name == "TodoWrite"
          display_todo_list(agent, entry[:timestamp])
        else
          @output.puts @event_renderer.tool_result(
            agent: agent,
            timestamp: entry[:timestamp],
            tool: tool_name,
          )

          # Render result content
          if entry[:result].is_a?(String) && !entry[:result].empty?
            result_text = @event_renderer.tool_result_content(
              entry[:result],
              indent: @depth_tracker.get(agent),
              truncate: !@verbose,
            )
            @output.puts result_text unless result_text.empty?
          end
        end

        @output.puts
        @output.puts @divider.event(indent: @depth_tracker.get(agent))

        # Start spinner for agent processing tool result
        # The agent will determine what to do next (more tools or finish)
        # This spinner will be stopped by the next agent_step or agent_stop event
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          indent = @depth_tracker.indent(agent)
          @spinner_manager.start(spinner_key, "#{indent}#{agent} is processing...")
        end
      end

      def handle_agent_delegation(entry)
        @usage_tracker.track_tool_call

        @output.puts @event_renderer.delegation(
          from: entry[:agent],
          to: entry[:delegate_to],
          timestamp: entry[:timestamp],
        )
        @output.puts

        # Show arguments if present
        if entry[:arguments] && !entry[:arguments].empty?
          @output.puts @event_renderer.tool_arguments(
            entry[:arguments],
            indent: @depth_tracker.get(entry[:agent]),
            truncate: @truncate,
          )
        end

        @output.puts

        # Start spinner waiting for delegated agent
        unless @quiet
          spinner_key = "delegation_#{entry[:delegate_to]}".to_sym
          indent = @depth_tracker.indent(entry[:agent])
          @spinner_manager.start(spinner_key, "#{indent}Waiting for #{entry[:delegate_to]}...")
        end
      end

      def handle_delegation_result(entry)
        @output.puts @event_renderer.delegation_result(
          from: entry[:delegate_from],
          to: entry[:agent],
          timestamp: entry[:timestamp],
        )

        # Render result content
        if entry[:result].is_a?(String) && !entry[:result].empty?
          result_text = @event_renderer.tool_result_content(
            entry[:result],
            indent: @depth_tracker.get(entry[:agent]),
            truncate: !@verbose,
          )
          @output.puts result_text unless result_text.empty?
        end

        @output.puts
        @output.puts @divider.event(indent: @depth_tracker.get(entry[:agent]))

        # Start spinner for agent processing delegation result
        unless @quiet
          spinner_key = "agent_#{entry[:agent]}".to_sym
          indent = @depth_tracker.indent(entry[:agent])
          @spinner_manager.start(spinner_key, "#{indent}#{entry[:agent]} is processing...")
        end
      end

      def handle_context_warning(entry)
        agent = entry[:agent]
        threshold = entry[:threshold]
        current_usage = entry[:current_usage]
        tokens_remaining = entry[:tokens_remaining]

        # Determine warning severity
        type = threshold == "90%" ? :error : :warning

        @output.puts @panel.render(
          type: type,
          title: "CONTEXT WARNING #{@agent_badge.render(agent)}",
          lines: [
            @pastel.public_send((type == :error ? :red : :yellow), "Context usage: #{current_usage} (threshold: #{threshold})"),
            @pastel.dim("Tokens remaining: #{SwarmCLI::UI::Formatters::Number.format(tokens_remaining)}"),
          ],
          indent: @depth_tracker.get(agent),
        )
      end

      def handle_model_lookup_warning(entry)
        agent = entry[:agent]
        model = entry[:model]
        error_message = entry[:error_message]
        suggestions = entry[:suggestions] || []

        lines = [
          @pastel.yellow("Model '#{model}' not found in registry"),
        ]

        if suggestions.any?
          lines << @pastel.dim("Did you mean one of these?")
          suggestions.each do |suggestion|
            model_id = suggestion[:id] || suggestion["id"]
            context = suggestion[:context_window] || suggestion["context_window"]
            context_display = context ? " (#{SwarmCLI::UI::Formatters::Number.format(context)} tokens)" : ""
            lines << "  #{@pastel.cyan("•")} #{@pastel.white(model_id)}#{@pastel.dim(context_display)}"
          end
        else
          lines << @pastel.dim("Error: #{error_message}")
        end

        lines << @pastel.dim("Context tracking unavailable for this model.")

        @output.puts @panel.render(
          type: :warning,
          title: "MODEL WARNING #{@agent_badge.render(agent)}",
          lines: lines,
          indent: 0, # Always at root level (warnings shown at boot, not during execution)
        )
      end

      def handle_compression_started(entry)
        agent = entry[:agent]
        message_count = entry[:message_count]
        estimated_tokens = entry[:estimated_tokens]

        @output.puts @panel.render(
          type: :info,
          title: "CONTEXT COMPRESSION #{@agent_badge.render(agent)}",
          lines: [
            @pastel.dim("Compressing #{message_count} messages (~#{SwarmCLI::UI::Formatters::Number.format(estimated_tokens)} tokens)..."),
          ],
          indent: @depth_tracker.get(agent),
        )
      end

      def handle_compression_completed(entry)
        agent = entry[:agent]
        original_messages = entry[:original_message_count]
        compressed_messages = entry[:compressed_message_count]
        messages_removed = entry[:messages_removed]
        original_tokens = entry[:original_tokens]
        compressed_tokens = entry[:compressed_tokens]
        compression_ratio = entry[:compression_ratio]
        time_taken = entry[:time_taken]

        @output.puts @panel.render(
          type: :success,
          title: "COMPRESSION COMPLETE #{@agent_badge.render(agent)}",
          lines: [
            "#{@pastel.dim("Messages:")} #{original_messages} → #{compressed_messages} #{@pastel.green("(-#{messages_removed})")}",
            "#{@pastel.dim("Tokens:")} #{SwarmCLI::UI::Formatters::Number.format(original_tokens)} → #{SwarmCLI::UI::Formatters::Number.format(compressed_tokens)} #{@pastel.green("(#{(compression_ratio * 100).round(1)}%)")}",
            "#{@pastel.dim("Time taken:")} #{SwarmCLI::UI::Formatters::Time.duration(time_taken)}",
          ],
          indent: @depth_tracker.get(agent),
        )
      end

      def handle_hook_executed(entry)
        hook_event = entry[:hook_event]
        agent = entry[:agent]
        success = entry[:success]
        blocked = entry[:blocked]
        stderr = entry[:stderr]
        exit_code = entry[:exit_code]

        @output.puts @event_renderer.hook_executed(
          hook_event: hook_event,
          agent: agent,
          timestamp: entry[:timestamp],
          success: success,
          blocked: blocked,
        )

        # Show stderr if present
        if stderr && !stderr.empty?
          indent = @depth_tracker.indent(agent)

          if blocked && hook_event == "user_prompt"
            @output.puts
            @output.puts "#{indent}  #{@pastel.bold.red("⛔ Prompt Blocked by Hook:")}"
            stderr.lines.each { |line| @output.puts "#{indent}  #{@pastel.red(line.chomp)}" }
            @output.puts "#{indent}  #{@pastel.dim("(Prompt was not sent to the agent)")}"
          elsif blocked
            @output.puts "#{indent}  #{@pastel.red("Blocked:")} #{@pastel.red(stderr)}"
          else
            @output.puts "#{indent}  #{@pastel.yellow("Message:")} #{@pastel.dim(stderr)}"
          end
        end

        # Show exit code in verbose mode
        if @verbose && exit_code
          indent = @depth_tracker.indent(agent)
          code_color = if exit_code.zero?
            :green
          else
            (exit_code == 2 ? :red : :yellow)
          end
          @output.puts "#{indent}  #{@pastel.dim("Exit code:")} #{@pastel.public_send(code_color, exit_code)}"
        end

        @output.puts
      end

      def handle_breakpoint_enter(entry)
        agent = entry[:agent]
        event = entry[:event]

        # Pause all spinners to allow clean interactive debugging
        @spinner_manager.pause_all

        # Show debugging notice
        @output.puts
        @output.puts @pastel.yellow("#{SwarmCLI::UI::Icons::THINKING} Breakpoint: Entering interactive debugging (#{event} hook)")
        @output.puts @pastel.dim("  Agent: #{agent}")
        @output.puts @pastel.dim("  Type 'exit' to continue execution")
        @output.puts
      end

      def handle_breakpoint_exit(entry)
        # Resume all spinners after debugging
        @spinner_manager.resume_all

        @output.puts
        @output.puts @pastel.green("#{SwarmCLI::UI::Icons::SUCCESS} Breakpoint: Resuming execution")
        @output.puts
      end

      def handle_llm_retry_attempt(entry)
        agent = entry[:agent]
        attempt = entry[:attempt]
        max_retries = entry[:max_retries]
        error_class = entry[:error_class]
        error_message = entry[:error_message]
        retry_delay = entry[:retry_delay]

        # Stop agent thinking spinner (if active)
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          @spinner_manager.stop(spinner_key) if @spinner_manager.active?(spinner_key)
        end

        lines = [
          @pastel.yellow("LLM API request failed (attempt #{attempt}/#{max_retries})"),
          @pastel.dim("Error: #{error_class}: #{error_message}"),
          @pastel.dim("Retrying in #{retry_delay}s..."),
        ]

        @output.puts @panel.render(
          type: :warning,
          title: "RETRY #{@agent_badge.render(agent)}",
          lines: lines,
          indent: @depth_tracker.get(agent),
        )

        # Restart spinner for next attempt
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          @spinner_manager.start(spinner_key, "#{agent} is retrying...")
        end
      end

      def handle_llm_retry_exhausted(entry)
        agent = entry[:agent]
        attempts = entry[:attempts]
        error_class = entry[:error_class]
        error_message = entry[:error_message]

        # Stop agent thinking spinner (if active)
        unless @quiet
          spinner_key = "agent_#{agent}".to_sym
          @spinner_manager.stop(spinner_key) if @spinner_manager.active?(spinner_key)
        end

        lines = [
          @pastel.red("LLM API request failed after #{attempts} attempts"),
          @pastel.dim("Error: #{error_class}: #{error_message}"),
          @pastel.dim("No more retries available"),
        ]

        @output.puts @panel.render(
          type: :error,
          title: "RETRY EXHAUSTED #{@agent_badge.render(agent)}",
          lines: lines,
          indent: @depth_tracker.get(agent),
        )
      end

      def display_todo_list(agent, timestamp)
        todos = SwarmSDK::Tools::Stores::TodoManager.get_todos(agent.to_sym)
        indent = @depth_tracker.indent(agent)
        time = SwarmCLI::UI::Formatters::Time.timestamp(timestamp)

        if todos.empty?
          @output.puts "#{indent}#{@pastel.dim(time)} #{@pastel.cyan("#{SwarmCLI::UI::Icons::BULLET} Todo list")} updated (empty)"
          return
        end

        @output.puts "#{indent}#{@pastel.dim(time)} #{@pastel.cyan("#{SwarmCLI::UI::Icons::BULLET} Todo list")} updated:"
        @output.puts

        todos.each_with_index do |todo, index|
          status = todo[:status] || todo["status"]
          content = todo[:content] || todo["content"]
          num = index + 1

          line = case status
          when "completed"
            "#{indent}  #{@pastel.dim("#{num}.")} #{@pastel.dim.strikethrough(content)}"
          when "in_progress"
            "#{indent}  #{@pastel.bold.yellow("#{num}.")} #{@pastel.bold(content)}"
          when "pending"
            "#{indent}  #{@pastel.white("#{num}.")} #{content}"
          else
            "#{indent}  #{num}. #{content}"
          end

          @output.puts line
        end
      end

      def print_header(swarm_name, lead_agent)
        @output.puts
        @output.puts @pastel.bold.bright_cyan("#{SwarmCLI::UI::Icons::SPARKLES} SwarmSDK - AI Agent Orchestration #{SwarmCLI::UI::Icons::SPARKLES}")
        @output.puts @divider.full
        @output.puts "#{@pastel.bold("Swarm:")} #{@pastel.cyan(swarm_name)}"
        @output.puts "#{@pastel.bold("Lead Agent:")} #{@pastel.cyan(lead_agent)}"
        @output.puts
      end

      def print_prompt(prompt)
        @output.puts @pastel.bold("#{SwarmCLI::UI::Icons::THINKING} Task Prompt:")
        @output.puts @pastel.bright_white(prompt)
        @output.puts
      end

      def print_result(result)
        return unless result.content && !result.content.empty?

        # Interactive mode: Just show the response content directly
        if @mode == :interactive
          # Render markdown if content looks like markdown
          content_to_display = if looks_like_markdown?(result.content)
            begin
              TTY::Markdown.parse(result.content)
            rescue StandardError
              result.content
            end
          else
            result.content
          end

          @output.puts content_to_display
          @output.puts
          return
        end

        # Non-interactive mode: Full result display with header and dividers
        @output.puts
        @output.puts @pastel.bold.green("#{SwarmCLI::UI::Icons::SUCCESS} Execution Complete")
        @output.puts
        @output.puts @pastel.bold("#{SwarmCLI::UI::Icons::RESPONSE} Final Response from #{@agent_badge.render(result.agent)}:")
        @output.puts
        @output.puts @divider.full

        # Render markdown if content looks like markdown
        content_to_display = if looks_like_markdown?(result.content)
          begin
            TTY::Markdown.parse(result.content)
          rescue StandardError
            result.content
          end
        else
          result.content
        end

        @output.puts content_to_display
        @output.puts @divider.full
        @output.puts
      end

      def print_summary(result)
        @output.puts @pastel.bold("#{SwarmCLI::UI::Icons::INFO} Execution Summary:")
        @output.puts

        # Agents used (colored list)
        agents_display = @agent_badge.render_list(@usage_tracker.agents)
        @output.puts "  #{SwarmCLI::UI::Icons::AGENT} #{@pastel.bold("Agents used:")} #{agents_display}"

        # Metrics
        @output.puts "  #{SwarmCLI::UI::Icons::LLM} #{@pastel.bold("LLM Requests:")} #{result.llm_requests}"
        @output.puts "  #{SwarmCLI::UI::Icons::TOOL} #{@pastel.bold("Tool Calls:")} #{result.tool_calls_count}"
        @output.puts "  #{SwarmCLI::UI::Icons::TOKENS} #{@pastel.bold("Total Tokens:")} #{SwarmCLI::UI::Formatters::Number.format(result.total_tokens)}"
        @output.puts "  #{SwarmCLI::UI::Icons::COST} #{@pastel.bold("Total Cost:")} #{SwarmCLI::UI::Formatters::Cost.format(result.total_cost, pastel: @pastel)}"
        @output.puts "  #{SwarmCLI::UI::Icons::TIME} #{@pastel.bold("Duration:")} #{SwarmCLI::UI::Formatters::Time.duration(result.duration)}"

        @output.puts
      end

      def print_error(error)
        @output.puts
        @output.puts @pastel.bold.red("#{SwarmCLI::UI::Icons::ERROR} Execution Failed")
        @output.puts
        @output.puts @pastel.red("Error: #{error.class.name}")
        @output.puts @pastel.red(error.message)
        @output.puts

        return unless error.backtrace

        @output.puts @pastel.dim("Backtrace:")
        error.backtrace.first(5).each do |line|
          @output.puts @pastel.dim("  #{line}")
        end
        @output.puts
      end

      def looks_like_markdown?(text)
        text.match?(/^#+\s|^\*\s|^-\s|^\d+\.\s|```|\[.+\]\(.+\)/)
      end
    end
  end
end
