# frozen_string_literal: true

# Extends RubyLLM::Configuration with additional options:
# - anthropic_api_base: Configurable Anthropic API base URL
# - read_timeout, open_timeout, write_timeout: Granular timeout configuration
# - Fixes Anthropic completion_url leading slash that breaks proxy base URLs
#
# Fork Reference: Commits da6144b, 3daa4fb

module RubyLLM
  class Configuration
    # Add new configuration accessors
    attr_accessor :anthropic_api_base,
      :read_timeout,
      :open_timeout,
      :write_timeout

    # Store original initialize for chaining
    alias_method :original_initialize_without_patches, :initialize

    # Override initialize to set default values for new options
    def initialize
      original_initialize_without_patches

      # Add new configuration options with defaults
      @anthropic_api_base = nil # Uses default 'https://api.anthropic.com' if not set
      @read_timeout = nil       # Defaults to request_timeout if not set
      @open_timeout = 30
      @write_timeout = 30
    end
  end

  # Patch Anthropic provider to use configurable base URL and fix completion_url
  module Providers
    class Anthropic
      # Override api_base to use configurable base URL
      def api_base
        @config.anthropic_api_base || "https://api.anthropic.com"
      end

      # Fix completion_url to use relative path (no leading slash).
      # The leading slash causes Faraday to discard the base URL path component,
      # breaking proxy configurations where api_base includes a path segment
      # (e.g., https://proxy.dev/apis/anthropic/v1/messages → https://proxy.dev/v1/messages).
      # stream_url delegates to completion_url, so this fixes both sync and streaming.
      # Can be removed once RubyLLM releases a version including upstream fix (commit da6144b).
      module Chat
        def completion_url
          "v1/messages"
        end
      end
    end
  end
end
