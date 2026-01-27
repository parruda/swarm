# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "tmpdir"

module SwarmSDK
  module Tools
    class ReadTest < Minitest::Test
      def setup
        @temp_dir = Dir.mktmpdir
        @test_file = File.join(@temp_dir, "test.txt")
      end

      def teardown
        FileUtils.rm_rf(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
        Stores::ReadTracker.clear_all
      end

      def test_read_tool_reads_file
        File.write(@test_file, "line 1\nline 2\nline 3\n")

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file)

        assert_includes(result, "line 1")
        assert_includes(result, "line 2")
        assert_includes(result, "line 3")
        # Should include system reminder
        assert_includes(result, "<system-reminder>")
      end

      def test_read_tool_with_offset_and_limit
        content = (1..100).map { |i| "line #{i}\n" }.join
        File.write(@test_file, content)

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file, offset: 10, limit: 5)

        assert_includes(result, "line 10")
        assert_includes(result, "line 14")
        refute_includes(result, "line 15")
        refute_includes(result, "line 9")
      end

      def test_read_tool_file_not_found
        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: "/nonexistent/file.txt")

        assert_includes(result, "<tool_use_error>")
        assert_includes(result, "File does not exist")
      end

      def test_read_tool_directory_error
        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @temp_dir)

        assert_includes(result, "directory")
      end

      def test_read_tool_empty_file_warning
        File.write(@test_file, "")

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file)

        assert_includes(result, "<system-reminder>")
        assert_includes(result, "empty contents")
      end

      def test_read_tool_registers_file_in_tracker
        File.write(@test_file, "test content")

        refute(Stores::ReadTracker.file_read?(:test_agent, @test_file), "File should not be tracked before reading")

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        tool.execute(file_path: @test_file)

        assert(Stores::ReadTracker.file_read?(:test_agent, @test_file), "File should be tracked after reading")
      end

      def test_read_tracker_isolates_agents
        File.write(@test_file, "test content")

        # Agent 1 reads the file
        tool1 = Read.new(agent_name: :agent1, directory: @temp_dir)
        tool1.execute(file_path: @test_file)

        # Agent 1 should have it tracked, but not Agent 2
        assert(Stores::ReadTracker.file_read?(:agent1, @test_file))
        refute(Stores::ReadTracker.file_read?(:agent2, @test_file))
      end

      def test_read_tool_with_nil_file_path
        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: nil)

        assert_includes(result, "Error: file_path is required")
      end

      def test_read_tool_with_blank_file_path
        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: "   ")

        assert_includes(result, "Error: file_path is required")
      end

      def test_read_tool_with_empty_file_path
        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: "")

        assert_includes(result, "Error: file_path is required")
      end

      def test_read_tool_offset_exceeds_file_length
        File.write(@test_file, "line 1\nline 2\nline 3\n")

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file, offset: 100)

        assert_includes(result, "<tool_use_error>")
        assert_includes(result, "Offset 100 exceeds file length")
      end

      def test_read_tool_handles_long_lines
        # Create a file with a very long line (> 2000 chars)
        long_line = "x" * 2500
        File.write(@test_file, long_line)

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file)

        # New implementation returns content without line truncation
        assert_includes(result, "x" * 2500)
        assert_includes(result, "<system-reminder>")
      end

      def test_read_tool_large_file_returns_content
        # Create a file with many lines
        content = (1..100).map { |i| "line #{i}\n" }.join
        File.write(@test_file, content)

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file)

        # New implementation uses token-based limits instead of line-based
        assert_includes(result, "line 1")
        assert_includes(result, "line 100")
        assert_includes(result, "<system-reminder>")
      end

      def test_read_tool_with_limit_specified
        content = (1..100).map { |i| "line #{i}\n" }.join
        File.write(@test_file, content)

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: @test_file, offset: 10, limit: 20)

        assert_includes(result, "line 10")
        assert_includes(result, "line 29")
        refute_includes(result, "line 30")
        # Should not include truncation reminder when limit is explicitly provided
        refute_includes(result, "only the first 2000 lines")
      end

      def test_read_tool_token_safeguard_rejects_large_files
        File.write(@test_file, "small content")

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)

        # Mock token counter to return a value exceeding MAX_TOKENS
        SwarmSDK::ContextCompactor::TokenCounter.stub(:estimate_content, 30_000) do
          result = tool.execute(file_path: @test_file)

          assert_includes(result, "Error:")
          assert_includes(result, "exceeds maximum allowed tokens")
          assert_includes(result, "offset and limit parameters")
        end
      end

      def test_read_tool_with_pdf_file_handles_gracefully
        pdf_file = File.join(@temp_dir, "test.pdf")
        # Create a file with actual binary content that cannot be UTF-8
        File.open(pdf_file, "wb") do |f|
          f.write([0xFF, 0xD8, 0xFF, 0xE0].pack("C*")) # JPEG magic bytes (similar binary pattern)
          f.write([0x80, 0x81, 0x82, 0x83].pack("C*")) # Invalid UTF-8 sequences
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: pdf_file)

        # Can return String (error or text-only PDF) or Content (PDF with images)
        assert(
          result.is_a?(String) || result.is_a?(RubyLLM::Content),
          "Result should be String or Content, got #{result.class}",
        )

        # If it's a string, it should not be empty
        # If it's Content, it should have text
        if result.is_a?(String)
          refute_empty(result)
        else
          refute_empty(result.text)
        end
      end

      def test_read_tool_with_supported_binary_file_png
        png_file = File.join(@temp_dir, "test.png")
        # Create a file with PNG magic bytes and binary content
        File.open(png_file, "wb") do |f|
          f.write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")) # PNG magic bytes
          f.write([0x80, 0x81, 0x82, 0x83].pack("C*"))
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: png_file)

        assert_instance_of(RubyLLM::Content, result)
        assert_includes(result.text, "test.png")
        assert_equal(1, result.attachments.size)
      end

      def test_read_tool_with_unsupported_binary_file
        binary_file = File.join(@temp_dir, "test.bin")
        # Create a file with binary content but unsupported extension
        File.open(binary_file, "wb") do |f|
          f.write([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x03].pack("C*"))
          f.write([0x80, 0x81, 0x82, 0x83].pack("C*"))
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: binary_file)

        assert_instance_of(String, result)
        assert_includes(result, "Error: File contains binary data")
        assert_includes(result, "cannot be displayed as text")
      end

      def test_read_tool_registers_binary_file_in_tracker
        png_file = File.join(@temp_dir, "test.png")
        File.open(png_file, "wb") do |f|
          f.write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")) # PNG magic bytes
          f.write([0x80, 0x81, 0x82, 0x83].pack("C*"))
        end

        refute(Stores::ReadTracker.file_read?(:test_agent, png_file), "File should not be tracked before reading")

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        tool.execute(file_path: png_file)

        assert(Stores::ReadTracker.file_read?(:test_agent, png_file), "Binary file should be tracked after reading")
      end

      def test_read_tool_with_docx_file_handles_gracefully
        docx_file = File.join(@temp_dir, "test.docx")
        File.open(docx_file, "wb") do |f|
          f.write([0x50, 0x4B, 0x03, 0x04].pack("C*")) # ZIP header (DOCX is a ZIP file)
          f.write([0x80, 0x81, 0x82, 0x83].pack("C*"))
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: docx_file)

        # Can return String (error or text-only DOCX) or Content (DOCX with images)
        assert(
          result.is_a?(String) || result.is_a?(RubyLLM::Content),
          "Result should be String or Content, got #{result.class}",
        )

        # If it's a string, it should not be empty
        # If it's Content, it should have text
        if result.is_a?(String)
          refute_empty(result)
        else
          refute_empty(result.text)
        end
      end

      def test_read_tool_with_xlsx_file_handles_gracefully
        xlsx_file = File.join(@temp_dir, "test.xlsx")
        File.open(xlsx_file, "wb") do |f|
          f.write([0x50, 0x4B, 0x03, 0x04].pack("C*")) # ZIP header (XLSX is a ZIP file)
          f.write([0x80, 0x81, 0x82, 0x83].pack("C*"))
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: xlsx_file)

        # Can return String (error or text-only XLSX) or Content (XLSX with images)
        assert(
          result.is_a?(String) || result.is_a?(RubyLLM::Content),
          "Result should be String or Content, got #{result.class}",
        )

        # If it's a string, it should not be empty
        # If it's Content, it should have text
        if result.is_a?(String)
          refute_empty(result)
        else
          refute_empty(result.text)
        end
      end

      def test_read_tool_with_doc_file_returns_error
        doc_file = File.join(@temp_dir, "test.doc")
        File.open(doc_file, "wb") do |f|
          f.write([0xD0, 0xCF, 0x11, 0xE0].pack("C*")) # OLE header
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: doc_file)

        # DOC format is explicitly not supported
        assert_instance_of(String, result)
        assert_includes(result, "Error:")
        assert_includes(result, "DOC format is not supported")
      end

      def test_read_tool_with_svg_file
        svg_file = File.join(@temp_dir, "test.svg")
        File.open(svg_file, "wb") do |f|
          f.write("<svg xmlns=\"http://www.w3.org/2000/svg\">")
          f.write([0x80, 0x81].pack("C*")) # Add some invalid UTF-8
        end

        tool = Read.new(agent_name: :test_agent, directory: @temp_dir)
        result = tool.execute(file_path: svg_file)

        assert_instance_of(RubyLLM::Content, result)
        assert_includes(result.text, "test.svg")
        assert_equal(1, result.attachments.size)
      end
    end
  end
end
