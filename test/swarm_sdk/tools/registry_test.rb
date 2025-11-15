# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Tools
    class RegistryTest < Minitest::Test
      def setup
        @temp_dir = Dir.mktmpdir
      end

      def teardown
        FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
      end

      def test_registry_get_tool_with_requirements
        # File tools return their actual class (not :special anymore)
        result = Registry.get(:Read)

        assert_equal(Read, result)
      end

      def test_registry_get_tool_regular
        # Regular tools return their class
        tool_class = Registry.get(:Bash)

        assert_equal(Bash, tool_class)
      end

      def test_registry_get_tool_string_name
        result = Registry.get("Read")

        assert_equal(Read, result)
      end

      def test_registry_get_many
        results = Registry.get_many([:Read, :Write, :Edit])

        assert_equal(3, results.size)
        # File tools return their actual classes
        assert_equal(Read, results[0])
        assert_equal(Write, results[1])
        assert_equal(Edit, results[2])
      end

      def test_registry_get_many_with_regular_tools
        results = Registry.get_many([:Bash, :Grep, :Glob])

        assert_equal(3, results.size)
        assert_equal(Bash, results[0])
        assert_equal(Grep, results[1])
        assert_equal(Glob, results[2])
      end

      def test_registry_get_many_invalid_tool
        error = assert_raises(ConfigurationError) do
          Registry.get_many([:Read, :InvalidTool])
        end
        assert_includes(error.message, "Unknown tool: InvalidTool")
      end

      def test_registry_exists
        assert(Registry.exists?(:Read))
        assert(Registry.exists?("Read"))
        assert(Registry.exists?(:Bash))
        refute(Registry.exists?(:InvalidTool))
      end

      def test_registry_available_names
        names = Registry.available_names

        assert_includes(names, :Read)
        assert_includes(names, :Write)
        assert_includes(names, :Edit)
        assert_includes(names, :MultiEdit)
        assert_includes(names, :TodoWrite)
        assert_includes(names, :Bash)
        assert_includes(names, :Grep)
        assert_includes(names, :Glob)
        assert_includes(names, :WebFetch)
        # Scratchpad tools (simplified)
        assert_includes(names, :ScratchpadWrite)
        assert_includes(names, :ScratchpadRead)
        assert_includes(names, :ScratchpadList)

        # Memory tools are provided by swarm_memory gem via plugin system
        # They are NOT in Tools::Registry - they're in PluginRegistry
        # So we should NOT expect them in available_names
        refute_includes(names, :MemoryWrite)
        refute_includes(names, :MemoryRead)
      end

      def test_registry_validate
        invalid = Registry.validate([:Read, :InvalidTool, :Write])

        assert_equal([:InvalidTool], invalid)
      end

      def test_special_tools_can_be_instantiated
        # File tools should be instantiable with agent_name parameter
        assert_respond_to(Read, :new)
        assert_respond_to(Write, :new)
        assert_respond_to(Edit, :new)
        assert_respond_to(MultiEdit, :new)
        assert_respond_to(TodoWrite, :new)
      end

      def test_special_tools_create_instances
        # Should be able to create tool instances for agents
        read_tool = Read.new(agent_name: :test, directory: @temp_dir)

        assert_respond_to(read_tool, :execute)

        write_tool = Write.new(agent_name: :test, directory: @temp_dir)

        assert_respond_to(write_tool, :execute)

        edit_tool = Edit.new(agent_name: :test, directory: @temp_dir)

        assert_respond_to(edit_tool, :execute)
      end

      # Factory Pattern Tests (Registry.create)

      def test_create_tool_with_agent_name_and_directory
        context = { agent_name: :test_agent, directory: @temp_dir }
        tool = Registry.create(:Read, context)

        assert_instance_of(Read, tool)
        assert_equal(:test_agent, tool.agent_name)
        assert_equal(File.expand_path(@temp_dir), tool.directory)
      end

      def test_create_tool_with_directory_only
        context = { agent_name: :unused, directory: @temp_dir }
        tool = Registry.create(:Bash, context)

        assert_instance_of(Bash, tool)
        assert_respond_to(tool, :execute)
      end

      def test_create_tool_with_agent_name_only
        context = { agent_name: :my_agent, directory: @temp_dir }
        tool = Registry.create(:TodoWrite, context)

        assert_instance_of(TodoWrite, tool)
        assert_respond_to(tool, :execute)
      end

      def test_create_tool_with_no_requirements
        context = {}
        tool = Registry.create(:Think, context)

        assert_instance_of(Think, tool)
        assert_respond_to(tool, :execute)
      end

      def test_create_tool_with_no_requirements_clock
        context = {}
        tool = Registry.create(:Clock, context)

        assert_instance_of(Clock, tool)
        assert_respond_to(tool, :execute)
      end

      def test_create_scratchpad_tool
        storage = Stores::ScratchpadStorage.new
        context = { scratchpad_storage: storage }
        tool = Registry.create(:ScratchpadWrite, context)

        assert_instance_of(Scratchpad::ScratchpadWrite, tool)
        assert_respond_to(tool, :execute)
      end

      def test_create_unknown_tool_raises_error
        error = assert_raises(ConfigurationError) do
          Registry.create(:UnknownTool, {})
        end
        assert_includes(error.message, "Unknown tool: UnknownTool")
      end

      def test_create_tool_with_missing_required_context
        error = assert_raises(ConfigurationError) do
          Registry.create(:Read, {}) # Missing agent_name and directory
        end
        assert_includes(error.message, "requires")
      end

      def test_create_tool_with_partial_context
        error = assert_raises(ConfigurationError) do
          Registry.create(:Read, { agent_name: :test }) # Missing directory
        end
        assert_includes(error.message, "directory")
      end

      def test_create_all_file_tools
        context = { agent_name: :test, directory: @temp_dir }

        read_tool = Registry.create(:Read, context)
        write_tool = Registry.create(:Write, context)
        edit_tool = Registry.create(:Edit, context)
        multi_edit_tool = Registry.create(:MultiEdit, context)

        assert_instance_of(Read, read_tool)
        assert_instance_of(Write, write_tool)
        assert_instance_of(Edit, edit_tool)
        assert_instance_of(MultiEdit, multi_edit_tool)

        # All should have same agent context
        [read_tool, write_tool, edit_tool, multi_edit_tool].each do |tool|
          assert_equal(:test, tool.agent_name)
          assert_equal(File.expand_path(@temp_dir), tool.directory)
        end
      end

      def test_create_all_search_tools
        context = { agent_name: :test, directory: @temp_dir }

        grep_tool = Registry.create(:Grep, context)
        glob_tool = Registry.create(:Glob, context)

        assert_instance_of(Grep, grep_tool)
        assert_instance_of(Glob, glob_tool)
      end

      def test_tool_creation_requirements_introspection
        # Tools should declare their requirements
        assert_equal([:agent_name, :directory], Read.creation_requirements)
        assert_equal([:agent_name, :directory], Write.creation_requirements)
        assert_equal([:agent_name, :directory], Edit.creation_requirements)
        assert_equal([:agent_name, :directory], MultiEdit.creation_requirements)
        assert_equal([:directory], Bash.creation_requirements)
        assert_equal([:directory], Grep.creation_requirements)
        assert_equal([:directory], Glob.creation_requirements)
        assert_equal([:agent_name], TodoWrite.creation_requirements)
      end

      def test_tools_without_requirements_have_no_method
        # Think and Clock don't need any context, so they don't define creation_requirements
        refute_respond_to(Think, :creation_requirements)
        refute_respond_to(Clock, :creation_requirements)
      end

      def test_create_scratchpad_without_storage_raises_error
        error = assert_raises(ConfigurationError) do
          Registry.create(:ScratchpadWrite, {})
        end
        assert_includes(error.message, "scratchpad_storage")
      end
    end
  end
end
