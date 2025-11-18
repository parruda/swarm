# frozen_string_literal: true

require "test_helper"

module SwarmMemory
  module Integration
    class SDKPluginTest < Minitest::Test
      def setup
        @plugin = SDKPlugin.new
      end

      # storage_enabled? tests (moved from SwarmSDK::Agent::Definition)
      # These test the plugin's ability to determine if memory is configured

      def test_storage_enabled_with_nil
        agent_def = create_agent_definition(memory: nil)

        refute(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_hash_and_directory
        agent_def = create_agent_definition(memory: { directory: "/tmp/memory" })

        assert(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_hash_and_string_key
        agent_def = create_agent_definition(memory: { "directory" => "/tmp/memory" })

        assert(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_empty_directory
        agent_def = create_agent_definition(memory: { directory: "" })

        refute(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_whitespace_directory
        agent_def = create_agent_definition(memory: { directory: "   " })

        refute(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_memory_config_object_enabled
        # Create a mock MemoryConfig object
        memory_config = Object.new
        def memory_config.enabled? = true

        agent_def = create_agent_definition(memory: memory_config)

        assert(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_memory_config_object_disabled
        # Create a mock MemoryConfig object that is disabled
        memory_config = Object.new
        def memory_config.enabled? = false

        agent_def = create_agent_definition(memory: memory_config)

        refute(@plugin.storage_enabled?(agent_def))
      end

      def test_storage_enabled_with_no_memory_key
        agent_def = create_agent_definition

        refute(@plugin.storage_enabled?(agent_def))
      end

      # translate_yaml_config tests

      def test_translate_yaml_config_with_full_config
        builder = MockBuilder.new
        agent_config = {
          memory: {
            directory: "/tmp/memory",
            adapter: :filesystem,
            mode: :researcher,
          },
        }

        @plugin.translate_yaml_config(builder, agent_config)

        assert_equal("/tmp/memory", builder.memory_config[:directory])
        assert_equal(:filesystem, builder.memory_config[:adapter])
        assert_equal(:researcher, builder.memory_config[:mode])
      end

      def test_translate_yaml_config_with_partial_config
        builder = MockBuilder.new
        agent_config = {
          memory: {
            directory: "/tmp/memory",
          },
        }

        @plugin.translate_yaml_config(builder, agent_config)

        assert_equal("/tmp/memory", builder.memory_config[:directory])
        assert_nil(builder.memory_config[:adapter])
        assert_nil(builder.memory_config[:mode])
      end

      def test_translate_yaml_config_without_memory
        builder = MockBuilder.new
        agent_config = { tools: [:Read] }

        @plugin.translate_yaml_config(builder, agent_config)

        assert_nil(builder.memory_config)
      end

      # serialize_config tests

      def test_serialize_config_with_memory
        memory_config = { directory: "/tmp/memory", mode: :researcher }
        agent_def = create_agent_definition(memory: memory_config)

        result = @plugin.serialize_config(agent_definition: agent_def)

        assert_equal({ memory: memory_config }, result)
      end

      def test_serialize_config_without_memory
        agent_def = create_agent_definition
        result = @plugin.serialize_config(agent_definition: agent_def)

        assert_empty(result)
      end

      private

      def create_agent_definition(memory: :not_set)
        config = {
          description: "Test agent",
          system_prompt: "Test prompt",
          directory: ".",
        }
        config[:memory] = memory unless memory == :not_set

        SwarmSDK::Agent::Definition.new(:test_agent, config)
      end

      # Mock builder for testing translate_yaml_config
      class MockBuilder
        attr_reader :memory_config

        def memory(&block)
          @memory_builder = MemoryBuilder.new
          @memory_builder.instance_eval(&block)
          @memory_config = @memory_builder.to_h
        end

        class MemoryBuilder
          def initialize
            @config = {}
          end

          def directory(value)
            @config[:directory] = value
          end

          def adapter(value)
            @config[:adapter] = value
          end

          def mode(value)
            @config[:mode] = value
          end

          def to_h
            @config
          end
        end
      end
    end
  end
end
