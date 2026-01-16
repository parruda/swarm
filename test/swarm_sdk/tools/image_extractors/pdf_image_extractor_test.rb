# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Tools
    module ImageExtractors
      class PdfImageExtractorTest < Minitest::Test
        def setup
          @temp_dir = Dir.mktmpdir("pdf_image_extractor_test")
        end

        def teardown
          FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
        end

        # Mock stream class for testing
        class MockStream
          attr_reader :hash, :data, :unfiltered_data

          def initialize(filter:, data: nil, unfiltered_data: nil, color_space: nil, width: nil, height: nil, bpc: nil)
            @hash = { Filter: filter }
            @hash[:ColorSpace] = color_space if color_space
            @hash[:Width] = width if width
            @hash[:Height] = height if height
            @hash[:BitsPerComponent] = bpc if bpc
            @data = data || ""
            @unfiltered_data = unfiltered_data || ""
          end
        end

        # Test JPEG images (DCTDecode) are extracted successfully
        def test_save_image_extracts_jpeg_with_dct_decode_filter
          jpeg_data = create_minimal_jpeg
          stream = MockStream.new(filter: :DCTDecode, data: jpeg_data)

          result = PdfImageExtractor.save_image(stream, 1, :img1, @temp_dir)

          refute_nil(result)
          assert(result.end_with?(".jpg"))
          assert_path_exists(result)
          assert_equal(jpeg_data, File.binread(result))
        end

        # Test FlateDecode images are skipped (not supported by LLM APIs)
        def test_save_image_skips_flate_decode_filter
          stream = MockStream.new(
            filter: :FlateDecode,
            unfiltered_data: "raw pixel data",
            color_space: :DeviceRGB,
            width: 100,
            height: 100,
            bpc: 8,
          )

          result = PdfImageExtractor.save_image(stream, 1, :img1, @temp_dir)

          assert_nil(result, "FlateDecode images should be skipped (TIFF not supported by LLM APIs)")
        end

        # Test LZWDecode images are skipped (not supported by LLM APIs)
        def test_save_image_skips_lzw_decode_filter
          stream = MockStream.new(
            filter: :LZWDecode,
            unfiltered_data: "raw pixel data",
            color_space: :DeviceRGB,
            width: 100,
            height: 100,
            bpc: 8,
          )

          result = PdfImageExtractor.save_image(stream, 1, :img1, @temp_dir)

          assert_nil(result, "LZWDecode images should be skipped (TIFF not supported by LLM APIs)")
        end

        # Test nil filter images are skipped (not supported by LLM APIs)
        def test_save_image_skips_nil_filter
          stream = MockStream.new(
            filter: nil,
            unfiltered_data: "raw pixel data",
            color_space: :DeviceGray,
            width: 50,
            height: 50,
            bpc: 8,
          )

          result = PdfImageExtractor.save_image(stream, 1, :img1, @temp_dir)

          assert_nil(result, "Images with nil filter should be skipped (TIFF not supported by LLM APIs)")
        end

        # Test unsupported filter formats return nil
        def test_save_image_returns_nil_for_unsupported_filters
          stream = MockStream.new(filter: :CCITTFaxDecode)

          result = PdfImageExtractor.save_image(stream, 1, :img1, @temp_dir)

          assert_nil(result, "Unsupported filter formats should return nil")
        end

        # Test error handling in save_image
        def test_save_image_returns_nil_on_error
          stream = MockStream.new(filter: :DCTDecode, data: nil)
          # Force an error by using an invalid temp_dir
          invalid_dir = "/nonexistent/directory/that/does/not/exist"

          result = PdfImageExtractor.save_image(stream, 1, :img1, invalid_dir)

          assert_nil(result, "Should return nil when an error occurs")
        end

        # Test save_jpeg creates correct filename
        def test_save_jpeg_creates_correct_filename
          jpeg_data = create_minimal_jpeg
          stream = MockStream.new(filter: :DCTDecode, data: jpeg_data)

          result = PdfImageExtractor.save_jpeg(stream, 3, :myimage, @temp_dir)

          expected_filename = File.join(@temp_dir, "page-3-myimage.jpg")

          assert_equal(expected_filename, result)
        end

        # Test extract_from_page filters only Image XObjects
        def test_extract_from_page_filters_only_image_xobjects
          jpeg_data = create_minimal_jpeg
          image_stream = MockStream.new(filter: :DCTDecode, data: jpeg_data)
          image_stream.hash[:Subtype] = :Image

          form_stream = MockStream.new(filter: :FlateDecode)
          form_stream.hash[:Subtype] = :Form

          page = Minitest::Mock.new
          page.expect(:xobjects, { img1: image_stream, form1: form_stream })

          result = PdfImageExtractor.extract_from_page(page, 1, @temp_dir)

          assert_equal(1, result.length, "Should only extract Image XObjects, not Form XObjects")
          assert(result.first.end_with?(".jpg"))

          page.verify
        end

        # Test extract_from_page returns empty array for empty xobjects
        def test_extract_from_page_returns_empty_for_no_xobjects
          page = Minitest::Mock.new
          page.expect(:xobjects, {})

          result = PdfImageExtractor.extract_from_page(page, 1, @temp_dir)

          assert_empty(result)
          page.verify
        end

        # Test extract_from_page handles errors gracefully
        def test_extract_from_page_handles_errors_gracefully
          page = Minitest::Mock.new
          page.expect(:xobjects, nil) { raise StandardError, "Page error" }

          result = PdfImageExtractor.extract_from_page(page, 1, @temp_dir)

          assert_empty(result, "Should return empty array on error")
        end

        # Test extract_images handles errors gracefully
        def test_extract_images_handles_errors_gracefully
          reader = Minitest::Mock.new
          reader.expect(:pages, nil) { raise StandardError, "Reader error" }

          result = PdfImageExtractor.extract_images(reader, "/tmp/test.pdf")

          assert_empty(result, "Should return empty array on error")
        end

        # Test extract_images processes multiple pages
        def test_extract_images_processes_multiple_pages
          jpeg_data = create_minimal_jpeg

          # Create mock streams for two pages
          stream1 = MockStream.new(filter: :DCTDecode, data: jpeg_data)
          stream1.hash[:Subtype] = :Image

          stream2 = MockStream.new(filter: :DCTDecode, data: jpeg_data)
          stream2.hash[:Subtype] = :Image

          page1 = Minitest::Mock.new
          page1.expect(:xobjects, { img1: stream1 })

          page2 = Minitest::Mock.new
          page2.expect(:xobjects, { img2: stream2 })

          reader = Minitest::Mock.new
          reader.expect(:pages, [page1, page2])

          # Capture the temp_dir creation
          Dir.method(:mktmpdir)
          Dir.stub(:mktmpdir, @temp_dir) do
            result = PdfImageExtractor.extract_images(reader, "/tmp/test.pdf")

            assert_equal(2, result.length, "Should extract images from both pages")
          end

          page1.verify
          page2.verify
          reader.verify
        end

        # Test that TIFF methods still exist but are not called for non-JPEG
        def test_tiff_methods_exist_for_future_use
          assert_respond_to(PdfImageExtractor, :save_as_tiff)
          assert_respond_to(PdfImageExtractor, :save_rgb_tiff)
          assert_respond_to(PdfImageExtractor, :save_gray_tiff)
        end

        private

        # Create a minimal valid JPEG for testing
        def create_minimal_jpeg
          # Minimal JPEG: SOI + APP0 + SOF0 + DHT + SOS + EOI markers
          # This is a valid 1x1 white pixel JPEG
          [
            0xFF,
            0xD8, # SOI (Start of Image)
            0xFF,
            0xE0,
            0x00,
            0x10, # APP0 marker and length
            0x4A,
            0x46,
            0x49,
            0x46,
            0x00, # "JFIF\0"
            0x01,
            0x01, # Version 1.1
            0x00, # Aspect ratio units (0 = no units)
            0x00,
            0x01, # X density
            0x00,
            0x01, # Y density
            0x00,
            0x00, # Thumbnail dimensions
            0xFF,
            0xD9, # EOI (End of Image)
          ].pack("C*")
        end
      end
    end
  end
end
