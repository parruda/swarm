# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "swarm_sdk"
require "minitest/autorun"
require "stringio"
require "tmpdir"

# WebMock for mocking HTTP requests
# WebMock has native support for async-http clients
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)

# CRITICAL: Override RubyLLM's Faraday adapter to use async-http
# RubyLLM hardcodes :net_http which blocks fibers when running inside Async contexts.
# This causes tests with Sync{} blocks to hang for 90+ seconds waiting for connection pools.
# By using :async_http, we get fiber-aware HTTP that cooperates with Async's scheduler.
# WebMock has native support for async-http clients (registered as :async_http_client).
require "async/http/faraday"

module AsyncHttpFaradayAdapter
  private

  def setup_middleware(faraday)
    faraday.request(:multipart)
    faraday.request(:json)
    faraday.response(:json)
    faraday.adapter(:async_http) # Use async-compatible adapter instead of :net_http
    faraday.use(:llm_errors, provider: @provider)
  end
end

RubyLLM::Connection.prepend(AsyncHttpFaradayAdapter)

# Load shared test helpers
require_relative "../helpers/llm_mock_helper"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

module SwarmSDK
  module TestHelpers
    # Helper to create a test scratchpad with temp file persistence
    # This prevents tests from writing to .swarm/scratchpad.json
    #
    # @return [SwarmSDK::Tools::Stores::Scratchpad] Scratchpad with temp file persistence
    def create_test_scratchpad
      # Create a volatile scratchpad for testing (no persistence)
      SwarmSDK::Tools::Stores::ScratchpadStorage.new
    end

    # Clean up test scratchpad files
    def cleanup_test_scratchpads
      return unless defined?(@test_scratchpad_files)

      @test_scratchpad_files&.each do |path|
        File.delete(path) if File.exist?(path)
      end
      @test_scratchpad_files = []
    end

    def silence_output
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      yield
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end

    def with_temp_dir(&block)
      Dir.mktmpdir("swarm_sdk_test", &block)
    end

    def with_temp_config(content)
      with_temp_dir do |dir|
        config_path = File.join(dir, "swarm.yml")
        File.write(config_path, content)
        yield config_path, dir
      end
    end

    # Helper to create agent definitions with sensible defaults for testing
    #
    # @param name [Symbol, String] Agent name
    # @param config [Hash] Agent configuration (optional fields)
    # @return [Agent::Definition] Fully configured agent definition
    #
    # @example
    #   swarm.add_agent(create_agent(name: :test))
    #   swarm.add_agent(create_agent(name: :backend, tools: [:Read, :Write]))
    def create_agent(name:, **config)
      # Provide sensible defaults for testing
      config[:description] ||= "Test agent #{name}"
      config[:model] ||= "gpt-5"
      config[:system_prompt] ||= "Test"

      SwarmSDK::Agent::Definition.new(name, config)
    end

    # Clean up LogCollector and LogStream state
    #
    # Call this in setup/teardown for tests that use swarm.execute with logging blocks
    # to ensure no frozen state leaks between tests.
    #
    # @return [void]
    def cleanup_logging_state
      begin
        SwarmSDK::LogCollector.reset!
      rescue StandardError
        nil
      end

      begin
        SwarmSDK::LogStream.reset!
      rescue StandardError
        nil
      end
    end
  end
end

Minitest::Test.include(SwarmSDK::TestHelpers)
Minitest::Test.include(LLMMockHelper)

original_home_dir = ENV["CLAUDE_SWARM_HOME"]
test_swarm_home = Dir.mktmpdir("swarm-sdk-test")
ENV["CLAUDE_SWARM_HOME"] = test_swarm_home

Minitest.after_run do
  FileUtils.rm_rf(test_swarm_home)
  ENV["CLAUDE_SWARM_HOME"] = original_home_dir
end
