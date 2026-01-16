# frozen_string_literal: true

module SwarmSDK
  module Tools
    module ImageExtractors
      # Extracts images from PDF documents
      # Only extracts JPEG images (DCTDecode format) which are LLM API compatible
      # Non-JPEG images (FlateDecode, LZWDecode) are skipped because they would
      # require TIFF format which is not supported by LLM APIs
      # Supported LLM image formats: ['png', 'jpeg', 'gif', 'webp']
      class PdfImageExtractor
        class << self
          # Extract all images from a PDF document
          # @param reader [PDF::Reader] The PDF reader instance
          # @param pdf_path [String] Path to the PDF file
          # @return [Array<String>] Array of temporary file paths containing extracted images
          def extract_images(reader, pdf_path)
            image_paths = []
            temp_dir = Dir.mktmpdir("pdf_images_#{File.basename(pdf_path, ".*")}")

            reader.pages.each_with_index do |page, page_index|
              page_images = extract_from_page(page, page_index + 1, temp_dir)
              image_paths.concat(page_images)
            end

            image_paths
          rescue StandardError
            # If image extraction fails, log it but don't fail the entire PDF read
            []
          end

          # Extract images from a single PDF page
          # @param page [PDF::Reader::Page] The PDF page
          # @param page_number [Integer] Page number (1-indexed)
          # @param temp_dir [String] Directory to save extracted images
          # @return [Array<String>] Array of file paths for extracted images
          def extract_from_page(page, page_number, temp_dir)
            extracted_files = []

            # Get XObjects (external objects) from the page
            xobjects = page.xobjects
            return extracted_files if xobjects.empty?

            xobjects.each do |name, stream|
              # Only process Image XObjects (not Form XObjects)
              next unless stream.hash[:Subtype] == :Image

              file_path = save_image(stream, page_number, name, temp_dir)
              extracted_files << file_path if file_path
            end

            extracted_files
          rescue StandardError
            # If extraction fails for this page, continue with others
            []
          end

          # Save a PDF image stream to disk
          # Supports JPEG (DCTDecode) and raw formats
          # @param stream [PDF::Reader::Stream] The image stream
          # @param page_number [Integer] Page number
          # @param name [Symbol] Image name from XObject
          # @param temp_dir [String] Directory to save the image
          # @return [String, nil] File path if successful, nil otherwise
          def save_image(stream, page_number, name, temp_dir)
            filter = stream.hash[:Filter]

            case filter
            when :DCTDecode
              # JPEG images can be saved directly - LLM API compatible
              save_jpeg(stream, page_number, name, temp_dir)
            when :FlateDecode, :LZWDecode, nil
              # Skip non-JPEG images to avoid TIFF format (not supported by LLM APIs)
              # LLM APIs only support: ['png', 'jpeg', 'gif', 'webp']
              # These images would require TIFF conversion which causes API errors
              nil
            end
            # Unsupported formats return nil
          rescue StandardError
            # If saving fails, skip this image
            nil
          end

          # Save JPEG image directly from PDF stream
          # @param stream [PDF::Reader::Stream] The image stream
          # @param page_number [Integer] Page number
          # @param name [Symbol] Image name
          # @param temp_dir [String] Directory to save the image
          # @return [String] File path
          def save_jpeg(stream, page_number, name, temp_dir)
            filename = File.join(temp_dir, "page-#{page_number}-#{name}.jpg")

            # JPEG images can be written directly - the stream.data contains a complete JPEG file
            File.open(filename, "wb") do |file|
              file.write(stream.data)
            end

            filename
          end

          # Save raw image data as TIFF
          # @param stream [PDF::Reader::Stream] The image stream
          # @param page_number [Integer] Page number
          # @param name [Symbol] Image name
          # @param temp_dir [String] Directory to save the image
          # @return [String, nil] File path if successful, nil for unsupported color spaces
          def save_as_tiff(stream, page_number, name, temp_dir)
            color_space = stream.hash[:ColorSpace]

            case color_space
            when :DeviceRGB
              save_rgb_tiff(stream, page_number, name, temp_dir)
            when :DeviceGray
              save_gray_tiff(stream, page_number, name, temp_dir)
            end
            # Unsupported color spaces return nil
          rescue StandardError
            # If conversion fails, skip this image
            nil
          end

          # Save RGB image as TIFF
          # @param stream [PDF::Reader::Stream] The image stream
          # @param page_number [Integer] Page number
          # @param name [Symbol] Image name
          # @param temp_dir [String] Directory to save the image
          # @return [String] File path
          def save_rgb_tiff(stream, page_number, name, temp_dir)
            filename = File.join(temp_dir, "page-#{page_number}-#{name}.tif")

            width = stream.hash[:Width]
            height = stream.hash[:Height]
            bpc = stream.hash[:BitsPerComponent] || 8

            # Build TIFF header
            tiff = ImageFormats::TiffBuilder.build_rgb_header(width, height, bpc)
            tiff << stream.unfiltered_data # Get decompressed raw pixel data

            File.open(filename, "wb") { |file| file.write(tiff) }
            filename
          end

          # Save grayscale image as TIFF
          # @param stream [PDF::Reader::Stream] The image stream
          # @param page_number [Integer] Page number
          # @param name [Symbol] Image name
          # @param temp_dir [String] Directory to save the image
          # @return [String] File path
          def save_gray_tiff(stream, page_number, name, temp_dir)
            filename = File.join(temp_dir, "page-#{page_number}-#{name}.tif")

            width = stream.hash[:Width]
            height = stream.hash[:Height]
            bpc = stream.hash[:BitsPerComponent] || 8

            # Build TIFF header for grayscale
            tiff = ImageFormats::TiffBuilder.build_gray_header(width, height, bpc)
            tiff << stream.unfiltered_data

            File.open(filename, "wb") { |file| file.write(tiff) }
            filename
          end
        end
      end
    end
  end
end
