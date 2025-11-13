# frozen_string_literal: true

module SwarmMemory
  module Integration
    # SwarmSDK plugin implementation for SwarmMemory
    #
    # This plugin integrates SwarmMemory with SwarmSDK, providing:
    # - Persistent memory storage for agents
    # - Memory tools (MemoryWrite, MemoryRead, MemoryEdit, etc.)
    # - LoadSkill tool for dynamic tool swapping
    # - System prompt contributions for memory guidance
    # - Semantic skill discovery on user messages
    #
    # The plugin automatically registers itself when SwarmMemory is loaded
    # alongside SwarmSDK.
    class SDKPlugin < SwarmSDK::Plugin
      def initialize
        super
        # Track storages for each agent: { agent_name => storage }
        # Needed for semantic skill discovery in on_user_message
        @storages = {}
        # Track memory mode for each agent: { agent_name => mode }
        # Modes: :assistant (default), :retrieval, :researcher
        @modes = {}
      end

      # Plugin identifier
      #
      # @return [Symbol] Plugin name
      def name
        :memory
      end

      # Tools provided by this plugin
      #
      # Returns all memory tools for PluginRegistry mapping.
      # Tools are auto-registered by ToolConfigurator, then filtered
      # by mode in on_agent_initialized using remove_tool.
      #
      # Note: LoadSkill is NOT included here because it requires special handling.
      # It's registered separately in on_agent_initialized lifecycle hook because
      # it needs chat, tool_configurator, and agent_definition parameters.
      #
      # @return [Array<Symbol>] All memory tool names
      def tools
        [
          :MemoryRead,
          :MemoryGlob,
          :MemoryGrep,
          :MemoryWrite,
          :MemoryEdit,
          :MemoryMultiEdit,
          :MemoryDelete,
          :MemoryDefrag,
        ]
      end

      # Get tools for a specific mode
      #
      # @param mode [Symbol] Memory mode
      # @return [Array<Symbol>] Tool names for this mode
      def tools_for_mode(mode)
        case mode
        when :retrieval
          # Read-only tools for Q&A agents
          [:MemoryRead, :MemoryGlob, :MemoryGrep]
        when :assistant
          # Read + Write + Edit for learning assistants (need edit for corrections)
          [:MemoryRead, :MemoryGlob, :MemoryGrep, :MemoryWrite, :MemoryEdit]
        when :researcher
          # All tools for knowledge extraction
          [
            :MemoryRead,
            :MemoryGlob,
            :MemoryGrep,
            :MemoryWrite,
            :MemoryEdit,
            :MemoryMultiEdit,
            :MemoryDelete,
            :MemoryDefrag,
          ]
        else
          # Default to assistant
          [:MemoryRead, :MemoryGlob, :MemoryGrep, :MemoryWrite, :MemoryEdit]
        end
      end

      # Create a tool instance
      #
      # @param tool_name [Symbol] Tool name
      # @param context [Hash] Creation context with :storage, :agent_name, :chat, etc.
      # @return [RubyLLM::Tool] Tool instance
      def create_tool(tool_name, context)
        storage = context[:storage]
        agent_name = context[:agent_name]

        # Delegate to SwarmMemory's tool factory
        SwarmMemory.create_tool(tool_name, storage: storage, agent_name: agent_name)
      end

      # Create plugin storage for an agent
      #
      # @param agent_name [Symbol] Agent identifier
      # @param config [Object] Memory configuration (MemoryConfig or Hash)
      # @return [Core::Storage] Storage instance with embeddings enabled
      def create_storage(agent_name:, config:)
        # Extract adapter type and options from config
        adapter_type, adapter_options = if config.respond_to?(:adapter_type)
          # MemoryConfig object (from DSL)
          [config.adapter_type, config.adapter_options]
        elsif config.is_a?(Hash)
          # Hash (from YAML)
          adapter = (config[:adapter] || config["adapter"] || :filesystem).to_sym
          options = config.reject { |k, _v| k == :adapter || k == "adapter" || k == :mode || k == "mode" }
          [adapter, options]
        else
          raise SwarmSDK::ConfigurationError, "Invalid memory configuration for #{agent_name}"
        end

        # Get adapter class from registry
        begin
          adapter_class = SwarmMemory.adapter_for(adapter_type)
        rescue ArgumentError => e
          raise SwarmSDK::ConfigurationError, "#{e.message} for agent #{agent_name}"
        end

        # Instantiate adapter with options
        # Note: Adapter is responsible for validating its own requirements
        begin
          adapter = adapter_class.new(**adapter_options)
        rescue ArgumentError => e
          raise SwarmSDK::ConfigurationError,
            "Failed to initialize #{adapter_type} adapter for #{agent_name}: #{e.message}"
        end

        # Create embedder for semantic search
        embedder = Embeddings::InformersEmbedder.new

        # Create storage with embedder (enables semantic features)
        Core::Storage.new(adapter: adapter, embedder: embedder)
      end

      # Parse memory configuration
      #
      # @param raw_config [Object] Raw config (MemoryConfig or Hash)
      # @return [Object] Parsed configuration
      def parse_config(raw_config)
        # Already parsed by Agent::Definition, just return as-is
        raw_config
      end

      # Contribute to agent system prompt
      #
      # @param agent_definition [Agent::Definition] Agent definition
      # @param storage [Core::Storage, nil] Storage instance (may be nil during prompt building)
      # @return [String] Memory prompt contribution
      def system_prompt_contribution(agent_definition:, storage:)
        # Extract mode from memory config
        memory_config = agent_definition.memory
        mode = if memory_config.is_a?(SwarmMemory::DSL::MemoryConfig)
          memory_config.mode # MemoryConfig object from DSL
        elsif memory_config.respond_to?(:mode)
          memory_config.mode # Other object with mode method
        elsif memory_config.is_a?(Hash)
          (memory_config[:mode] || memory_config["mode"] || :assistant).to_sym
        else
          :assistant # Default mode
        end

        # Select prompt template based on mode
        prompt_filename = case mode
        when :retrieval then "memory_retrieval.md.erb"
        when :researcher then "memory_researcher.md.erb"
        else "memory_assistant.md.erb" # Default
        end

        memory_prompt_path = File.expand_path("../prompts/#{prompt_filename}", __dir__)
        template_content = File.read(memory_prompt_path)

        # Render with agent_definition binding
        ERB.new(template_content).result(agent_definition.instance_eval { binding })
      end

      # Tools that should be marked immutable (mode-aware)
      #
      # Memory tools for the current mode plus LoadSkill (if applicable) are immutable.
      # This prevents LoadSkill from accidentally removing memory tools.
      #
      # @param mode [Symbol] Memory mode
      # @return [Array<Symbol>] Immutable tool names for this mode
      def immutable_tools_for_mode(mode)
        base_tools = tools_for_mode(mode)

        # LoadSkill only for assistant and researcher modes (not retrieval)
        if mode == :retrieval
          base_tools
        else
          base_tools + [:LoadSkill]
        end
      end

      # Check if storage should be created for this agent
      #
      # @param agent_definition [Agent::Definition] Agent definition
      # @return [Boolean] True if agent has memory configuration
      def storage_enabled?(agent_definition)
        agent_definition.memory_enabled?
      end

      # Contribute to agent serialization
      #
      # Preserves memory configuration when agents are cloned (e.g., in Workflow).
      # This allows memory configuration to persist across node transitions.
      #
      # @param agent_definition [Agent::Definition] Agent definition
      # @return [Hash] Memory config to include in to_h
      def serialize_config(agent_definition:)
        return {} unless agent_definition.memory

        { memory: agent_definition.memory }
      end

      # Lifecycle: Agent initialized
      #
      # Filters tools by mode (removing non-mode tools), registers LoadSkill,
      # and marks memory tools as immutable.
      #
      # LoadSkill needs special handling because it requires chat, tool_configurator,
      # and agent_definition to perform dynamic tool swapping.
      #
      # @param agent_name [Symbol] Agent identifier
      # @param agent [Agent::Chat] Chat instance
      # @param context [Hash] Initialization context
      def on_agent_initialized(agent_name:, agent:, context:)
        storage = context[:storage]
        agent_definition = context[:agent_definition]
        tool_configurator = context[:tool_configurator]

        return unless storage # Only proceed if memory is enabled for this agent

        # Extract mode from memory config
        memory_config = agent_definition.memory
        mode = if memory_config.is_a?(SwarmMemory::DSL::MemoryConfig)
          memory_config.mode # MemoryConfig object from DSL
        elsif memory_config.respond_to?(:mode)
          memory_config.mode # Other object with mode method
        elsif memory_config.is_a?(Hash)
          (memory_config[:mode] || memory_config["mode"] || :interactive).to_sym
        else
          :interactive # Default
        end

        # V7.0: Extract base name for storage tracking (delegation instances share storage)
        base_name = agent_name.to_s.split("@").first.to_sym

        # Store storage and mode using BASE NAME
        @storages[base_name] = storage # ← Changed from agent_name to base_name
        @modes[base_name] = mode # ← Changed from agent_name to base_name

        # Get mode-specific tools
        allowed_tools = tools_for_mode(mode)

        # Get all registered memory tool names
        all_memory_tools = tools # Returns all possible memory tools

        # Remove tools not allowed in this mode
        tools_to_remove = all_memory_tools - allowed_tools

        tools_to_remove.each do |tool_name|
          agent.remove_tool(tool_name)
        end

        # Create and register LoadSkill tool (NOT for retrieval mode - read-only)
        unless mode == :retrieval
          load_skill_tool = SwarmMemory.create_tool(
            :LoadSkill,
            storage: storage,
            agent_name: agent_name,
            chat: agent,
            tool_configurator: tool_configurator,
            agent_definition: agent_definition,
          )

          agent.with_tool(load_skill_tool)
        end

        # Mark mode-specific memory tools + LoadSkill as immutable
        agent.mark_tools_immutable(immutable_tools_for_mode(mode).map(&:to_s))
      end

      # Lifecycle: User message
      #
      # Performs TWO semantic searches:
      # 1. Skills - For loadable procedures with LoadSkill
      # 2. Memories - For concepts/facts/experiences that provide context
      #
      # Returns system reminders for both if high-confidence matches found.
      #
      # @param agent_name [Symbol] Agent identifier
      # @param prompt [String] User's message
      # @param is_first_message [Boolean] True if first message
      # @return [Array<String>] System reminders (0-2 reminders)
      def on_user_message(agent_name:, prompt:, is_first_message:)
        # V7.0: Extract base name for storage lookup (delegation instances share storage)
        base_name = agent_name.to_s.split("@").first.to_sym
        storage = @storages[base_name] # ← Changed from agent_name to base_name

        return [] unless storage&.semantic_index
        return [] if prompt.nil? || prompt.empty?

        # Adaptive threshold based on query length
        # Short queries use lower threshold as they have less semantic richness
        # Optimal: cutoff=10 words, short=0.25, normal=0.35 (discovered via systematic evaluation)
        word_count = prompt.split.size
        word_cutoff = (ENV["SWARM_MEMORY_ADAPTIVE_WORD_CUTOFF"] || "10").to_i

        threshold = if word_count < word_cutoff
          (ENV["SWARM_MEMORY_DISCOVERY_THRESHOLD_SHORT"] || "0.25").to_f
        else
          (ENV["SWARM_MEMORY_DISCOVERY_THRESHOLD"] || "0.35").to_f
        end
        reminders = []

        # Run both searches in parallel with Async
        Async do |task|
          # Search 1: Skills (type = "skill")
          skills_task = task.async do
            storage.semantic_index.search(
              query: prompt,
              top_k: 3,
              threshold: threshold,
              filter: { "type" => "skill" },
            )
          end

          # Search 2: All results (for memories + logging)
          all_results_task = task.async do
            storage.semantic_index.search(
              query: prompt,
              top_k: 10,
              threshold: 0.0, # Get all for logging
              filter: nil,
            )
          end

          # Wait for both searches to complete
          skills = skills_task.wait
          all_results = all_results_task.wait

          # Filter to concepts, facts, experiences (not skills)
          memories = all_results
            .select { |r| ["concept", "fact", "experience"].include?(r.dig(:metadata, "type")) }
            .select { |r| r[:similarity] >= threshold }
            .take(3)

          # Emit log events (include word count for adaptive threshold analysis)
          search_context = { threshold: threshold, word_count: word_count, word_cutoff: word_cutoff }
          emit_skill_search_log(agent_name, prompt, skills, all_results, search_context)
          emit_memory_search_log(agent_name, prompt, memories, all_results, search_context)

          # Build skill reminder if found
          if skills.any?
            reminders << build_skill_discovery_reminder(skills)
          end

          # Build memory reminder if found
          if memories.any?
            reminders << build_memory_discovery_reminder(memories)
          end
        end.wait

        reminders
      end

      private

      # Emit log event for semantic skill search
      #
      # @param agent_name [Symbol] Agent identifier
      # @param prompt [String] User's message
      # @param skills [Array<Hash>] Found skills (filtered)
      # @param all_results [Array<Hash>] All search results (unfiltered)
      # @param search_context [Hash] Search context with :threshold and :word_count
      # @return [void]
      def emit_skill_search_log(agent_name, prompt, skills, all_results, search_context)
        return unless SwarmSDK::LogStream.enabled?

        threshold = search_context[:threshold]
        word_count = search_context[:word_count]
        word_cutoff = search_context[:word_cutoff]

        # Include top 5 results for debugging (even if below threshold or wrong type)
        all_entries_debug = all_results.take(5).map do |result|
          {
            path: result[:path],
            title: result[:title],
            hybrid_score: result[:similarity].round(3),
            semantic_score: result[:semantic_score]&.round(3),
            keyword_score: result[:keyword_score]&.round(3),
            type: result.dig(:metadata, "type"),
            tags: result.dig(:metadata, "tags"),
          }
        end

        # Get actual weights being used (from ENV or defaults)
        semantic_weight = (ENV["SWARM_MEMORY_SEMANTIC_WEIGHT"] || "0.5").to_f
        keyword_weight = (ENV["SWARM_MEMORY_KEYWORD_WEIGHT"] || "0.5").to_f

        SwarmSDK::LogStream.emit(
          type: "semantic_skill_search",
          agent: agent_name,
          query: prompt,
          query_word_count: word_count,
          threshold: threshold,
          threshold_type: word_count < word_cutoff ? "short_query" : "normal_query",
          adaptive_cutoff: word_cutoff,
          skills_found: skills.size,
          total_entries_searched: all_results.size,
          search_mode: "hybrid",
          weights: { semantic: semantic_weight, keyword: keyword_weight },
          skills: skills.map do |skill|
            {
              path: skill[:path],
              title: skill[:title],
              hybrid_score: skill[:similarity].round(3),
              semantic_score: skill[:semantic_score]&.round(3),
              keyword_score: skill[:keyword_score]&.round(3),
            }
          end,
          debug_top_results: all_entries_debug,
        )
      end

      # Emit log event for semantic memory search
      #
      # @param agent_name [Symbol] Agent identifier
      # @param prompt [String] User's message
      # @param memories [Array<Hash>] Found memories (concepts/facts/experiences)
      # @param all_results [Array<Hash>] All search results (unfiltered)
      # @param search_context [Hash] Search context with :threshold and :word_count
      # @return [void]
      def emit_memory_search_log(agent_name, prompt, memories, all_results, search_context)
        return unless SwarmSDK::LogStream.enabled?

        threshold = search_context[:threshold]
        word_count = search_context[:word_count]
        word_cutoff = search_context[:word_cutoff]

        # Filter all_results to only concept/fact/experience types for debug output
        memory_entries = all_results.select do |r|
          ["concept", "fact", "experience"].include?(r.dig(:metadata, "type"))
        end

        # Include top 10 memory entries for debugging (even if below threshold)
        debug_all_memories = memory_entries.take(10).map do |result|
          {
            path: result[:path],
            title: result[:title],
            hybrid_score: result[:similarity].round(3),
            semantic_score: result[:semantic_score]&.round(3),
            keyword_score: result[:keyword_score]&.round(3),
            type: result.dig(:metadata, "type"),
            tags: result.dig(:metadata, "tags"),
            domain: result.dig(:metadata, "domain"),
          }
        end

        # Get actual weights being used (from ENV or defaults)
        semantic_weight = (ENV["SWARM_MEMORY_SEMANTIC_WEIGHT"] || "0.5").to_f
        keyword_weight = (ENV["SWARM_MEMORY_KEYWORD_WEIGHT"] || "0.5").to_f

        SwarmSDK::LogStream.emit(
          type: "semantic_memory_search",
          agent: agent_name,
          query: prompt,
          query_word_count: word_count,
          threshold: threshold,
          threshold_type: word_count < word_cutoff ? "short_query" : "normal_query",
          adaptive_cutoff: word_cutoff,
          memories_found: memories.size,
          total_memory_entries_searched: memory_entries.size,
          search_mode: "hybrid",
          weights: { semantic: semantic_weight, keyword: keyword_weight },
          memories: memories.map do |memory|
            {
              path: memory[:path],
              title: memory[:title],
              type: memory.dig(:metadata, "type"),
              hybrid_score: memory[:similarity].round(3),
              semantic_score: memory[:semantic_score]&.round(3),
              keyword_score: memory[:keyword_score]&.round(3),
            }
          end,
          debug_top_results: debug_all_memories,
        )
      end

      # Build system reminder for discovered skills
      #
      # @param skills [Array<Hash>] Skill search results
      # @return [String] Formatted system reminder
      def build_skill_discovery_reminder(skills)
        reminder = "<system-reminder>\n"
        reminder += "🎯 Found #{skills.size} skill(s) in memory that may be relevant:\n\n"

        skills.each do |skill|
          match_pct = (skill[:similarity] * 100).round
          reminder += "**#{skill[:title]}** (#{match_pct}% match)\n"
          reminder += "Path: `#{skill[:path]}`\n"
          reminder += "To use: `LoadSkill(file_path: \"#{skill[:path]}\")`\n\n"
        end

        reminder += "**If a skill matches your task:** Load it to get step-by-step instructions and adapted tools.\n"
        reminder += "**If none match (false positive):** Ignore and proceed normally.\n"
        reminder += "</system-reminder>"

        reminder
      end

      # Build system reminder for discovered memories
      #
      # @param memories [Array<Hash>] Memory search results (concepts/facts/experiences)
      # @return [String] Formatted system reminder
      def build_memory_discovery_reminder(memories)
        reminder = "<system-reminder>\n"
        reminder += "📚 Found #{memories.size} memory entr#{memories.size == 1 ? "y" : "ies"} that may provide context:\n\n"

        memories.each do |memory|
          match_pct = (memory[:similarity] * 100).round
          type = memory.dig(:metadata, "type")
          type_emoji = case type
          when "concept" then "💡"
          when "fact" then "📋"
          when "experience" then "🔍"
          else "📄"
          end

          reminder += "#{type_emoji} **#{memory[:title]}** (#{type}, #{match_pct}% match)\n"
          reminder += "Path: `#{memory[:path]}`\n"
          reminder += "Read with: `MemoryRead(file_path: \"#{memory[:path]}\")`\n\n"
        end

        reminder += "**These entries may contain relevant knowledge for your task.**\n"
        reminder += "Read them to inform your approach, or ignore if not helpful.\n"
        reminder += "</system-reminder>"

        reminder
      end
    end
  end
end
