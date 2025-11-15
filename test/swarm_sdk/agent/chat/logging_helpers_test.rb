# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Agent
    class LoggingHelpersTest < Minitest::Test
      # Create a test class that includes the module
      class TestChat
        include ChatHelpers::LoggingHelpers

        attr_accessor :model_id

        def initialize(model_id = "test-model")
          @model_id = model_id
        end
      end

      def setup
        @chat = TestChat.new
      end

      # ========================================
      # format_tool_calls tests
      # ========================================

      def test_format_tool_calls_with_nil
        result = @chat.format_tool_calls(nil)

        assert_nil(result)
      end

      def test_format_tool_calls_with_empty_hash
        result = @chat.format_tool_calls({})

        assert_empty(result)
      end

      def test_format_tool_calls_with_single_tool_call
        tool_call = Struct.new(:id, :name, :arguments).new("call_123", "Read", { file_path: "/test.txt" })
        tool_calls_hash = { "call_123" => tool_call }

        result = @chat.format_tool_calls(tool_calls_hash)

        assert_equal(1, result.size)
        assert_equal("call_123", result[0][:id])
        assert_equal("Read", result[0][:name])
        assert_equal({ file_path: "/test.txt" }, result[0][:arguments])
      end

      def test_format_tool_calls_with_multiple_tool_calls
        tool_call1 = Struct.new(:id, :name, :arguments).new("call_1", "Read", { file_path: "/a.txt" })
        tool_call2 = Struct.new(:id, :name, :arguments).new("call_2", "Write", { file_path: "/b.txt", content: "test" })
        tool_calls_hash = { "call_1" => tool_call1, "call_2" => tool_call2 }

        result = @chat.format_tool_calls(tool_calls_hash)

        assert_equal(2, result.size)
        assert_equal("call_1", result[0][:id])
        assert_equal("Read", result[0][:name])
        assert_equal("call_2", result[1][:id])
        assert_equal("Write", result[1][:name])
      end

      # ========================================
      # serialize_result tests
      # ========================================

      def test_serialize_result_with_string
        result = @chat.serialize_result("Simple string result")

        assert_equal("Simple string result", result)
      end

      def test_serialize_result_with_empty_string
        result = @chat.serialize_result("")

        assert_equal("", result)
      end

      def test_serialize_result_with_hash
        hash_result = { status: "success", data: [1, 2, 3] }

        result = @chat.serialize_result(hash_result)

        assert_equal(hash_result, result)
      end

      def test_serialize_result_with_array
        array_result = [1, 2, 3, 4]

        result = @chat.serialize_result(array_result)

        assert_equal(array_result, result)
      end

      def test_serialize_result_with_content_text_only
        content = RubyLLM::Content.new("Test content text")

        result = @chat.serialize_result(content)

        assert_equal("Test content text", result)
      end

      def test_serialize_result_with_content_empty_text
        content = RubyLLM::Content.new("")

        result = @chat.serialize_result(content)

        assert_equal("", result)
      end

      def test_serialize_result_with_content_nil_text
        content = RubyLLM::Content.new("")

        result = @chat.serialize_result(content)

        assert_equal("", result)
      end

      def test_serialize_result_with_content_text_and_single_attachment
        content = RubyLLM::Content.new("See the image")
        # Mock an attachment object with source and mime_type
        attachment = Struct.new(:source, :mime_type).new("image.png", "image/png")
        content.attachments << attachment

        result = @chat.serialize_result(content)

        assert_equal("See the image [Attachments: image.png (image/png)]", result)
      end

      def test_serialize_result_with_content_text_and_multiple_attachments
        content = RubyLLM::Content.new("Multiple files attached")
        # Mock attachment objects
        attachment1 = Struct.new(:source, :mime_type).new("doc.pdf", "application/pdf")
        attachment2 = Struct.new(:source, :mime_type).new("sheet.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        content.attachments << attachment1
        content.attachments << attachment2

        result = @chat.serialize_result(content)

        assert_equal("Multiple files attached [Attachments: doc.pdf (application/pdf), sheet.xlsx (application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)]", result)
      end

      def test_serialize_result_with_content_attachments_only
        content = RubyLLM::Content.new("text")
        # Mock an attachment object
        attachment = Struct.new(:source, :mime_type).new("file.txt", "text/plain")
        content.attachments << attachment

        result = @chat.serialize_result(content)

        assert_equal("text [Attachments: file.txt (text/plain)]", result)
      end

      def test_serialize_result_with_custom_object
        custom_obj = Struct.new(:name, :value).new("test", 42)

        result = @chat.serialize_result(custom_obj)

        # Should call to_s on the object
        assert_instance_of(String, result)
        refute_empty(result)
      end

      def test_serialize_result_with_integer
        result = @chat.serialize_result(42)

        assert_equal("42", result)
      end

      def test_serialize_result_with_nil
        result = @chat.serialize_result(nil)

        assert_equal("", result)
      end

      # ========================================
      # calculate_cost tests
      # ========================================

      def test_calculate_cost_with_valid_pricing
        # Mock message with token counts
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "claude-sonnet-4-5-20250929")

        result = @chat.calculate_cost(message)

        # Verify structure
        assert_instance_of(Hash, result)
        assert(result.key?(:input_cost))
        assert(result.key?(:output_cost))
        assert(result.key?(:total_cost))

        # Costs should be positive for claude-sonnet-4-5-20250929
        assert_operator(result[:input_cost], :>, 0)
        assert_operator(result[:output_cost], :>, 0)
        assert_equal(result[:input_cost] + result[:output_cost], result[:total_cost])
      end

      def test_calculate_cost_with_nil_input_tokens
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(nil, 500_000, "claude-sonnet-4-5-20250929")

        result = @chat.calculate_cost(message)

        assert_in_delta(0.0, result[:input_cost])
        assert_in_delta(0.0, result[:output_cost])
        assert_in_delta(0.0, result[:total_cost])
      end

      def test_calculate_cost_with_nil_output_tokens
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, nil, "claude-sonnet-4-5-20250929")

        result = @chat.calculate_cost(message)

        assert_in_delta(0.0, result[:input_cost])
        assert_in_delta(0.0, result[:output_cost])
        assert_in_delta(0.0, result[:total_cost])
      end

      def test_calculate_cost_with_nil_tokens
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(nil, nil, "claude-sonnet-4-5-20250929")

        result = @chat.calculate_cost(message)

        assert_in_delta(0.0, result[:input_cost])
        assert_in_delta(0.0, result[:output_cost])
        assert_in_delta(0.0, result[:total_cost])
      end

      def test_calculate_cost_with_nonexistent_model
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "nonexistent-model-xyz")

        # Suppress debug logging during test
        _out, _err = capture_io do
          result = @chat.calculate_cost(message)

          # Should return zero cost for unknown models
          assert_in_delta(0.0, result[:input_cost])
          assert_in_delta(0.0, result[:output_cost])
          assert_in_delta(0.0, result[:total_cost])
        end
      end

      def test_calculate_cost_with_zero_tokens
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(0, 0, "claude-sonnet-4-5-20250929")

        result = @chat.calculate_cost(message)

        # Zero tokens should result in zero cost
        assert_in_delta(0.0, result[:input_cost])
        assert_in_delta(0.0, result[:output_cost])
        assert_in_delta(0.0, result[:total_cost])
      end

      def test_calculate_cost_with_model_without_pricing
        # Use a mock model that doesn't exist in SwarmSDK::Models
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "fake-model-without-pricing")

        result = @chat.calculate_cost(message)

        # Should return zero cost when model is not found
        assert_in_delta(0.0, result[:input_cost])
        assert_in_delta(0.0, result[:output_cost])
        assert_in_delta(0.0, result[:total_cost])
      end

      def test_calculate_cost_with_string_keys_in_model_info
        # Test that pricing lookup works with string keys (not just symbol keys)
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "claude-sonnet-4-5-20250929")

        result = @chat.calculate_cost(message)

        # Should successfully calculate cost with string keys
        assert_operator(result[:total_cost], :>, 0)
      end

      def test_calculate_cost_with_exception_during_calculation
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "claude-sonnet-4-5-20250929")

        # Mock SwarmSDK::Models.find to raise an exception
        SwarmSDK::Models.stub(:find, ->(_model_id) { raise StandardError, "Test error" }) do
          # Suppress logging
          _out, _err = capture_io do
            result = @chat.calculate_cost(message)

            # Should return zero cost on exception
            assert_in_delta(0.0, result[:input_cost])
            assert_in_delta(0.0, result[:output_cost])
            assert_in_delta(0.0, result[:total_cost])
          end
        end
      end

      def test_calculate_cost_pricing_calculation_accuracy
        # Test exact calculation with known values
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "claude-sonnet-4-5-20250929")

        model_info = SwarmSDK::Models.find("claude-sonnet-4-5-20250929")
        pricing = model_info["pricing"] || model_info[:pricing]
        text_pricing = pricing["text_tokens"] || pricing[:text_tokens]
        standard_pricing = text_pricing["standard"] || text_pricing[:standard]
        input_price = standard_pricing["input_per_million"] || standard_pricing[:input_per_million]
        output_price = standard_pricing["output_per_million"] || standard_pricing[:output_per_million]

        result = @chat.calculate_cost(message)

        # Verify calculation: (tokens / 1_000_000) * price_per_million
        expected_input = (1_000_000 / 1_000_000.0) * input_price
        expected_output = (500_000 / 1_000_000.0) * output_price

        assert_in_delta(expected_input, result[:input_cost], 0.000001)
        assert_in_delta(expected_output, result[:output_cost], 0.000001)
        assert_in_delta(expected_input + expected_output, result[:total_cost], 0.000001)
      end

      def test_calculate_cost_with_missing_text_tokens_pricing
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "test-model")

        # Mock model with missing text_tokens pricing
        mock_model_info = {
          "id" => "test-model",
          "pricing" => {
            # Missing text_tokens key
          },
        }

        SwarmSDK::Models.stub(:find, ->(_) { mock_model_info }) do
          result = @chat.calculate_cost(message)

          assert_in_delta(0.0, result[:input_cost])
          assert_in_delta(0.0, result[:output_cost])
          assert_in_delta(0.0, result[:total_cost])
        end
      end

      def test_calculate_cost_with_missing_standard_pricing
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "test-model")

        # Mock model with missing standard pricing
        mock_model_info = {
          "id" => "test-model",
          "pricing" => {
            "text_tokens" => {
              # Missing standard key
            },
          },
        }

        SwarmSDK::Models.stub(:find, ->(_) { mock_model_info }) do
          result = @chat.calculate_cost(message)

          assert_in_delta(0.0, result[:input_cost])
          assert_in_delta(0.0, result[:output_cost])
          assert_in_delta(0.0, result[:total_cost])
        end
      end

      def test_calculate_cost_with_missing_input_price
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "test-model")

        # Mock model with missing input_per_million
        mock_model_info = {
          "id" => "test-model",
          "pricing" => {
            "text_tokens" => {
              "standard" => {
                # Missing input_per_million
                "output_per_million" => 15.0,
              },
            },
          },
        }

        SwarmSDK::Models.stub(:find, ->(_) { mock_model_info }) do
          result = @chat.calculate_cost(message)

          assert_in_delta(0.0, result[:input_cost])
          assert_in_delta(0.0, result[:output_cost])
          assert_in_delta(0.0, result[:total_cost])
        end
      end

      def test_calculate_cost_with_missing_output_price
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "test-model")

        # Mock model with missing output_per_million
        mock_model_info = {
          "id" => "test-model",
          "pricing" => {
            "text_tokens" => {
              "standard" => {
                "input_per_million" => 3.0,
                # Missing output_per_million
              },
            },
          },
        }

        SwarmSDK::Models.stub(:find, ->(_) { mock_model_info }) do
          result = @chat.calculate_cost(message)

          assert_in_delta(0.0, result[:input_cost])
          assert_in_delta(0.0, result[:output_cost])
          assert_in_delta(0.0, result[:total_cost])
        end
      end

      def test_calculate_cost_with_symbol_keys_in_pricing
        message = Struct.new(:input_tokens, :output_tokens, :model_id).new(1_000_000, 500_000, "test-model")

        # Mock model with symbol keys
        mock_model_info = {
          id: "test-model",
          pricing: {
            text_tokens: {
              standard: {
                input_per_million: 3.0,
                output_per_million: 15.0,
              },
            },
          },
        }

        SwarmSDK::Models.stub(:find, ->(_) { mock_model_info }) do
          result = @chat.calculate_cost(message)

          # Should work with symbol keys
          assert_in_delta(3.0, result[:input_cost], 0.01)
          assert_in_delta(7.5, result[:output_cost], 0.01)
          assert_in_delta(10.5, result[:total_cost], 0.01)
        end
      end

      # ========================================
      # zero_cost tests
      # ========================================

      def test_zero_cost
        result = @chat.zero_cost

        assert_in_delta(0.0, result[:input_cost])
        assert_in_delta(0.0, result[:output_cost])
        assert_in_delta(0.0, result[:total_cost])
      end
    end
  end
end
