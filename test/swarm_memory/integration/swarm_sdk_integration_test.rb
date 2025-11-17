# frozen_string_literal: true

require_relative "../../swarm_memory_test_helper"

class SwarmSDKIntegrationTest < Minitest::Test
  def setup
    @temp_memory_dir = File.join(Dir.tmpdir, "test-swarm-memory-#{SecureRandom.hex(8)}")
    FileUtils.mkdir_p(@temp_memory_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_memory_dir) if @temp_memory_dir && Dir.exist?(@temp_memory_dir)
  end

  def test_swarm_with_memory_configuration
    # Skip if swarm_memory not loaded
    skip("swarm_memory gem not loaded") unless defined?(SwarmMemory)

    swarm = SwarmSDK::Swarm.new(name: "Test Swarm")

    # Create agent with memory (directory path, not JSON file)
    agent_def = SwarmSDK::Agent::Definition.new(:test_agent, {
      description: "Test agent with memory",
      model: "gpt-4",
      memory: {
        adapter: :filesystem,
        directory: File.join(@temp_memory_dir, "agent-memory"),
      },
    })

    swarm.add_agent(agent_def)
    swarm.lead = :test_agent

    # Agent should have memory tools available
    # Use plugin's storage_enabled? method (memory_enabled? is no longer in SDK)
    plugin = SwarmMemory::Integration::SDKPlugin.new

    assert(plugin.storage_enabled?(agent_def))
  end

  def test_memory_tools_created_correctly
    skip("swarm_memory gem not loaded") unless defined?(SwarmMemory)

    # Create storage
    temp_dir = File.join(@temp_memory_dir, "test-storage")
    adapter = SwarmMemory::Adapters::FilesystemAdapter.new(directory: temp_dir)
    storage = SwarmMemory::Core::Storage.new(adapter: adapter)

    # Test tool creation via SwarmMemory.create_tool
    tool = SwarmMemory.create_tool(:MemoryWrite, storage: storage, agent_name: :test)

    assert_instance_of(SwarmMemory::Tools::MemoryWrite, tool)
    assert_equal("MemoryWrite", tool.name)
  end

  def test_batch_tool_creation
    skip("swarm_memory gem not loaded") unless defined?(SwarmMemory)

    # Create storage
    temp_dir = File.join(@temp_memory_dir, "test-storage2")
    adapter = SwarmMemory::Adapters::FilesystemAdapter.new(directory: temp_dir)
    storage = SwarmMemory::Core::Storage.new(adapter: adapter)

    # Test batch creation
    tools = SwarmMemory.tools_for(storage: storage, agent_name: :test)

    assert_equal(8, tools.size)
    assert_includes(tools.map(&:name), "MemoryWrite")
    assert_includes(tools.map(&:name), "MemoryRead")
    assert_includes(tools.map(&:name), "MemoryDefrag")
  end
end
