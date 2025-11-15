# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module Tools
    module Stores
      class StorageTest < Minitest::Test
        # Create a concrete test implementation to test the abstract base class
        class TestStorage < Storage
          def initialize
            super
            @test_data = {}
          end

          def write(file_path:, content:, title:)
            @test_data[file_path] = Entry.new(
              content: content,
              title: title,
              updated_at: Time.now.iso8601,
              size: content.bytesize,
            )
          end

          def read(file_path:)
            raise ArgumentError, "Path not found: #{file_path}" unless @test_data.key?(file_path)

            @test_data[file_path].content
          end

          def delete(file_path:)
            raise ArgumentError, "Path not found: #{file_path}" unless @test_data.key?(file_path)

            @test_data.delete(file_path)
          end

          def list(prefix: nil)
            entries = @test_data.keys
            entries = entries.select { |k| k.start_with?(prefix) } if prefix
            entries.map { |path| { path: path } }
          end

          def glob(pattern:)
            regex = glob_to_regex(pattern)
            @test_data.keys.select { |path| regex.match?(path) }.map { |path| { path: path } }
          end

          def grep(pattern:, case_insensitive: false, output_mode: "files_with_matches")
            regex = case_insensitive ? Regexp.new(pattern, Regexp::IGNORECASE) : Regexp.new(pattern)
            matches = @test_data.select { |_path, entry| regex.match?(entry.content) }

            case output_mode
            when "files_with_matches"
              matches.keys.map { |path| { path: path } }
            when "content"
              matches.map { |path, entry| { path: path, content: entry.content } }
            when "count"
              matches.map { |path, entry| { path: path, count: entry.content.scan(regex).size } }
            end
          end

          def clear
            @test_data.clear
          end

          def total_size
            @test_data.values.sum(&:size)
          end

          def size
            @test_data.size
          end

          # Expose protected methods for testing
          def test_format_bytes(bytes)
            format_bytes(bytes)
          end

          def test_glob_to_regex(pattern)
            glob_to_regex(pattern)
          end
        end

        def setup
          @storage = TestStorage.new
        end

        def test_format_bytes_for_bytes
          assert_equal("500B", @storage.test_format_bytes(500))
          assert_equal("999B", @storage.test_format_bytes(999))
          assert_equal("0B", @storage.test_format_bytes(0))
        end

        def test_format_bytes_for_kilobytes
          assert_equal("1.0KB", @storage.test_format_bytes(1000))
          assert_equal("1.5KB", @storage.test_format_bytes(1500))
          assert_equal("999.9KB", @storage.test_format_bytes(999_900))
        end

        def test_format_bytes_for_megabytes
          assert_equal("1.0MB", @storage.test_format_bytes(1_000_000))
          assert_equal("2.5MB", @storage.test_format_bytes(2_500_000))
          assert_equal("100.0MB", @storage.test_format_bytes(100_000_000))
        end

        def test_glob_to_regex_with_double_star
          regex = @storage.test_glob_to_regex("**/*.txt")

          # Current implementation: **/ requires at least one directory separator
          refute_match(regex, "foo.txt") # No directory in path
          assert_match(regex, "dir/foo.txt")
          assert_match(regex, "dir/subdir/foo.txt")
          refute_match(regex, "foo.md")
          refute_match(regex, "dir/foo.md")
        end

        def test_glob_to_regex_with_single_star
          regex = @storage.test_glob_to_regex("dir/*/file.txt")

          assert_match(regex, "dir/subdir/file.txt")
          assert_match(regex, "dir/foo/file.txt")
          refute_match(regex, "dir/subdir/nested/file.txt")
          refute_match(regex, "dir/file.txt")
        end

        def test_glob_to_regex_with_question_mark
          regex = @storage.test_glob_to_regex("file_?.txt")

          assert_match(regex, "file_1.txt")
          assert_match(regex, "file_a.txt")
          refute_match(regex, "file_12.txt")
          refute_match(regex, "file_.txt")
        end

        def test_glob_to_regex_complex_pattern
          regex = @storage.test_glob_to_regex("parallel/*/task_?.md")

          assert_match(regex, "parallel/batch1/task_1.md")
          assert_match(regex, "parallel/batch2/task_a.md")
          refute_match(regex, "parallel/batch1/nested/task_1.md")
          refute_match(regex, "parallel/batch1/task_12.md")
        end

        def test_glob_to_regex_anchors
          regex = @storage.test_glob_to_regex("*.txt")

          assert_match(regex, "file.txt")
          refute_match(regex, "prefix_file.txt_suffix")
          refute_match(regex, "dir/file.txt")
        end

        def test_abstract_methods_raise_not_implemented_error
          storage = Storage.new

          assert_raises(NotImplementedError) { storage.write(file_path: "test", content: "test", title: "test") }
          assert_raises(NotImplementedError) { storage.read(file_path: "test") }
          assert_raises(NotImplementedError) { storage.delete(file_path: "test") }
          assert_raises(NotImplementedError) { storage.list }
          assert_raises(NotImplementedError) { storage.glob(pattern: "**/*") }
          assert_raises(NotImplementedError) { storage.grep(pattern: "test") }
          assert_raises(NotImplementedError) { storage.clear }
          assert_raises(NotImplementedError) { storage.total_size }
          assert_raises(NotImplementedError) { storage.size }
        end

        def test_entry_struct
          entry = Storage::Entry.new(
            content: "test content",
            title: "Test Title",
            updated_at: "2025-01-01T00:00:00Z",
            size: 12,
          )

          assert_equal("test content", entry.content)
          assert_equal("Test Title", entry.title)
          assert_equal("2025-01-01T00:00:00Z", entry.updated_at)
          assert_equal(12, entry.size)
        end

        def test_max_entry_size_constant
          assert_equal(3_000_000, Defaults::Storage::ENTRY_SIZE_BYTES)
        end

        def test_max_total_size_constant
          assert_equal(100_000_000_000, Defaults::Storage::TOTAL_SIZE_BYTES)
        end
      end
    end
  end
end
