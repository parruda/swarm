# frozen_string_literal: true

# Load dependencies first (before Zeitwerk)
require "json"
require "yaml"
require "fileutils"
require "time"
require "date"
require "set"

require "async"
require "async/semaphore"
require "swarm_sdk"
require "ruby_llm"

# Try to load informers (optional, for embeddings)
begin
  require "informers"
rescue LoadError
  # Informers not available - embeddings will be disabled
  warn("Warning: informers gem not found. Semantic search will be unavailable. Run: gem install informers")
end

# Load errors and version first
require_relative "swarm_memory/errors"
require_relative "swarm_memory/version"

# Setup Zeitwerk loader
require "zeitwerk"
loader = Zeitwerk::Loader.new
loader.tag = File.basename(__FILE__, ".rb")
loader.push_dir("#{__dir__}/swarm_memory", namespace: SwarmMemory)
loader.inflector = Zeitwerk::GemInflector.new(__FILE__)
loader.inflector.inflect(
  "cli" => "CLI",
  "dsl" => "DSL",
  "sdk_plugin" => "SDKPlugin",
)
loader.setup

# Explicitly load DSL components and extensions to inject into SwarmSDK
# These must be loaded after Zeitwerk but before anything uses them
require_relative "swarm_memory/dsl/memory_config"
require_relative "swarm_memory/dsl/builder_extension"
# NOTE: ChatExtension was removed in favor of SDK's built-in remove_tool method

module SwarmMemory
  class << self
    # Registry for custom adapters
    def adapter_registry
      @adapter_registry ||= {}
    end

    # Register a custom adapter
    #
    # @param name [Symbol] Adapter name
    # @param klass [Class] Adapter class (must inherit from Adapters::Base)
    #
    # @example
    #   SwarmMemory.register_adapter(:activerecord, ActiveRecordMemoryAdapter)
    def register_adapter(name, klass)
      unless klass < Adapters::Base
        raise ArgumentError, "Adapter must inherit from SwarmMemory::Adapters::Base"
      end

      adapter_registry[name.to_sym] = klass
    end

    # Get adapter class by name
    #
    # @param name [Symbol] Adapter name
    # @return [Class] Adapter class
    # @raise [ArgumentError] If adapter is not found
    def adapter_for(name)
      name = name.to_sym

      # Check built-in adapters first
      case name
      when :filesystem
        Adapters::FilesystemAdapter
      else
        # Check registry
        adapter_registry[name] || raise(ArgumentError, "Unknown adapter: #{name}. Available: #{available_adapters.join(", ")}")
      end
    end

    # Get list of available adapters
    #
    # @return [Array<Symbol>] List of registered adapter names
    def available_adapters
      [:filesystem] + adapter_registry.keys
    end

    # Create individual tool instance
    # Called by SwarmSDK's ToolConfigurator
    #
    # @param tool_name [Symbol] Tool name
    # @param storage [SwarmMemory::Core::Storage] Storage instance
    # @param agent_name [String, Symbol] Agent identifier
    # @param options [Hash] Additional options for special tools like LoadSkill
    # @option options [SwarmSDK::Agent::Chat] :chat Chat instance (for LoadSkill)
    # @option options [SwarmSDK::ToolConfigurator] :tool_configurator Tool configurator (for LoadSkill)
    # @option options [SwarmSDK::Agent::Definition] :agent_definition Agent definition (for LoadSkill)
    # @return [RubyLLM::Tool] Configured tool instance
    def create_tool(tool_name, storage:, agent_name:, **options)
      # Validate storage is present
      if storage.nil?
        raise ConfigurationError,
          "Cannot create #{tool_name} tool: memory storage is nil. " \
            "Did you configure memory for this agent? " \
            "Add: memory { directory '.swarm/agent-memory' }"
      end

      case tool_name.to_sym
      when :MemoryWrite
        Tools::MemoryWrite.new(storage: storage, agent_name: agent_name)
      when :MemoryRead
        Tools::MemoryRead.new(storage: storage, agent_name: agent_name)
      when :MemoryEdit
        Tools::MemoryEdit.new(storage: storage, agent_name: agent_name)
      when :MemoryMultiEdit
        Tools::MemoryMultiEdit.new(storage: storage, agent_name: agent_name)
      when :MemoryDelete
        Tools::MemoryDelete.new(storage: storage)
      when :MemoryGlob
        Tools::MemoryGlob.new(storage: storage)
      when :MemoryGrep
        Tools::MemoryGrep.new(storage: storage)
      when :MemoryDefrag
        Tools::MemoryDefrag.new(storage: storage)
      when :LoadSkill
        # LoadSkill requires additional context for tool swapping
        Tools::LoadSkill.new(
          storage: storage,
          agent_name: agent_name,
          chat: options[:chat],
          tool_configurator: options[:tool_configurator],
          agent_definition: options[:agent_definition],
        )
      else
        raise ConfigurationError, "Unknown memory tool: #{tool_name}"
      end
    end

    # Convenience method for creating all memory tools at once
    # Useful for direct RubyLLM usage (not via SwarmSDK)
    #
    # @param storage [SwarmMemory::Core::Storage] Storage instance
    # @param agent_name [String, Symbol] Agent identifier
    # @return [Array<RubyLLM::Tool>] All configured memory tools
    def tools_for(storage:, agent_name:)
      [
        Tools::MemoryWrite.new(storage: storage, agent_name: agent_name),
        Tools::MemoryRead.new(storage: storage, agent_name: agent_name),
        Tools::MemoryEdit.new(storage: storage, agent_name: agent_name),
        Tools::MemoryMultiEdit.new(storage: storage, agent_name: agent_name),
        Tools::MemoryDelete.new(storage: storage),
        Tools::MemoryGlob.new(storage: storage),
        Tools::MemoryGrep.new(storage: storage),
        Tools::MemoryDefrag.new(storage: storage),
      ]
    end
  end
end

# Auto-register with SwarmSDK when loaded
require_relative "swarm_memory/integration/sdk_plugin"
require_relative "swarm_memory/integration/registration"
SwarmMemory::Integration::Registration.register!

# Auto-register CLI commands with SwarmCLI when loaded
require_relative "swarm_memory/integration/cli_registration"
SwarmMemory::Integration::CliRegistration.register!
