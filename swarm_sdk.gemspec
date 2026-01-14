# frozen_string_literal: true

require_relative "lib/swarm_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "swarm_sdk"
  spec.version = SwarmSDK::VERSION
  spec.authors = ["Paulo Arruda"]
  spec.email = ["parrudaj@gmail.com"]

  spec.summary = "Lightweight multi-agent AI orchestration using RubyLLM"
  spec.description = <<~DESC
    SwarmSDK is a complete reimagining of Claude Swarm that runs all AI agents in a single process
    using RubyLLM for LLM interactions. Define collaborative AI agents in simple Markdown files with
    YAML frontmatter, and orchestrate them without the overhead of multiple processes or MCP
    inter-process communication. Perfect for building lightweight, efficient AI agent teams with
    specialized roles and capabilities.
  DESC
  spec.homepage = "https://github.com/parruda/swarm"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = "https://github.com/parruda/swarm"
  spec.metadata["changelog_uri"] = "https://github.com/parruda/swarm/blob/main/docs/v2/CHANGELOG.swarm_sdk.md"

  spec.files = IO.popen(["git", "ls-files", "-z"], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select do |f|
      (f == "lib/swarm_sdk.rb") ||
        f.match?(%r{\Alib/swarm_sdk/}) || (f == "LICENSE")
    end
  end
  # spec.bindir = "exe"
  # spec.executables = []
  spec.require_paths = ["lib"]

  spec.add_dependency("async", "~> 2.0")
  spec.add_dependency("async-http-faraday", "~> 0.22")
  spec.add_dependency("faraday-follow_redirects", "~> 0.4")
  spec.add_dependency("openssl", "~> 3.3.2")
  spec.add_dependency("ruby_llm_swarm", "~> 1.9.7")
  spec.add_dependency("ruby_llm_swarm-mcp", "~> 0.8.2")
  spec.add_dependency("zeitwerk", "~> 2.6")
end
