# frozen_string_literal: true

require_relative "lib/swarm_memory/version"

Gem::Specification.new do |spec|
  spec.name          = "swarm_memory"
  spec.version       = SwarmMemory::VERSION
  spec.authors       = ["Paulo Arruda"]
  spec.email         = ["parrudaj@gmail.com"]
  spec.summary       = "Persistent memory system for SwarmSDK agents"
  spec.description   = "Hierarchical persistent memory with semantic search for SwarmSDK AI agents"
  spec.homepage      = "https://github.com/parruda/swarm"
  spec.license       = "MIT"
  spec.metadata["source_code_uri"] = "https://github.com/parruda/swarm"
  spec.metadata["changelog_uri"] = "https://github.com/parruda/swarm/blob/main/docs/v2/CHANGELOG.swarm_memory.md"

  spec.files = IO.popen(["git", "ls-files", "-z"], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select do |f|
      (f == "lib/swarm_memory.rb") ||
        f.match?(%r{\Alib/swarm_memory/}) || (f == "LICENSE")
    end
  end
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2.0"

  # Core dependencies
  spec.add_dependency("async", "~> 2.0")
  spec.add_dependency("informers", "~> 1.2.1")
  spec.add_dependency("rice", "~> 4.6.0")
  spec.add_dependency("ruby_llm", "~> 1.11")
  spec.add_dependency("swarm_sdk", "~> 2.7")
  spec.add_dependency("zeitwerk", "~> 2.6")
end
