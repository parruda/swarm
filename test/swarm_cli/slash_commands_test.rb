# frozen_string_literal: true

require_relative "../test_helper"
require "swarm_cli"
require "stringio"
require "tempfile"

module SwarmCLI
  class SlashCommandsTest < Minitest::Test
    def setup
      @original_api_key = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "test-key-12345"
      RubyLLM.configure { |config| config.openai_api_key = "test-key-12345" }

      @temp_dir = Dir.mktmpdir("slash-commands-test")

      # Create temp config file for Options
      @temp_config = Tempfile.new(["test_config", ".yml"])
      @temp_config.write("version: 2\nagents:\n  test:\n    system_prompt: test")
      @temp_config.close
    end

    def teardown
      FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
      @temp_config&.unlink
      ENV["OPENAI_API_KEY"] = @original_api_key
      RubyLLM.configure { |config| config.openai_api_key = @original_api_key }
    end

    def test_clear_command_clears_agent_context
      # Create swarm with agent
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          coding_agent(false)
          tools(:Read)
          directory(@temp_dir)
        end
      end

      # Get lead agent
      lead = swarm.agent(swarm.lead_agent)

      # Create REPL first (may add system messages)
      options = SwarmCLI::Options.new
      options.parse([@temp_config.path, "-q"])
      repl = SwarmCLI::InteractiveREPL.new(swarm: swarm, options: options)

      # Add some messages to the agent's conversation
      lead.add_message(role: :user, content: "Message 1")
      lead.add_message(role: :assistant, content: "Response 1")
      lead.add_message(role: :user, content: "Message 2")

      # Get message count before clear
      messages_before = lead.messages.size

      assert_operator(messages_before, :>, 0, "Should have messages before clear")

      # Capture output and execute /clear command
      output = capture_io do
        repl.handle_command("/clear")
      end

      # Verify agent's messages were cleared
      assert_equal(0, lead.messages.size)

      # Verify confirmation message
      assert_match(/Conversation context cleared/, output.join)
    end

    def test_tools_command_lists_available_tools
      # Create swarm with tools
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          coding_agent(false)
          tools(:Read, :Write, :Edit, :Bash)
          directory(@temp_dir)
        end
      end

      options = SwarmCLI::Options.new
      options.parse([@temp_config.path, "-q"])
      repl = SwarmCLI::InteractiveREPL.new(swarm: swarm, options: options)

      # Capture output and execute /tools command
      output = capture_io do
        repl.handle_command("/tools")
      end

      output_text = output.join

      # Verify tool categories are shown
      assert_match(/Available Tools for agent1/, output_text)
      assert_match(/Standard Tools:/, output_text)

      # Verify specific tools are listed
      assert_match(/Read/, output_text)
      assert_match(/Write/, output_text)
      assert_match(/Edit/, output_text)
      assert_match(/Bash/, output_text)

      # Verify total count
      assert_match(/Total:/, output_text)
    end

    def test_tools_command_shows_memory_tools_when_memory_enabled
      memory_dir = File.join(@temp_dir, ".memory")

      # Create swarm with memory
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Test agent")
          coding_agent(false)
          tools(:Read)
          directory(@temp_dir)

          memory do
            directory(memory_dir)
          end
        end
      end

      options = SwarmCLI::Options.new
      options.parse([@temp_config.path, "-q"])
      repl = SwarmCLI::InteractiveREPL.new(swarm: swarm, options: options)

      # Capture output and execute /tools command
      output = capture_io do
        repl.handle_command("/tools")
      end

      output_text = output.join

      # Verify memory tools are shown
      assert_match(/Memory Tools:/, output_text)
      assert_match(/MemoryWrite/, output_text)
      assert_match(/MemoryRead/, output_text)
      assert_match(/LoadSkill/, output_text)
    end

    def test_tools_command_shows_delegation_tools
      # Create swarm with delegation
      swarm = SwarmSDK.build do
        name("Test Swarm")
        lead(:agent1)

        agent(:agent1) do
          description("Lead agent")
          coding_agent(false)
          tools(:Read)
          delegates_to(:agent2)
          directory(@temp_dir)
        end

        agent(:agent2) do
          description("Helper agent")
          coding_agent(false)
          tools(:Write)
          directory(@temp_dir)
        end
      end

      options = SwarmCLI::Options.new
      options.parse([@temp_config.path, "-q"])
      repl = SwarmCLI::InteractiveREPL.new(swarm: swarm, options: options)

      # Capture output and execute /tools command
      output = capture_io do
        repl.handle_command("/tools")
      end

      output_text = output.join

      # Verify delegation tools are shown
      assert_match(/Delegation Tools:/, output_text)
      assert_match(/WorkWithAgent2/, output_text)
    end
  end
end
