# frozen_string_literal: true

# Extends RubyLLM::Connection with:
# - Connection.basic uses net_http adapter for SSL/IPv6 compatibility
# - Granular timeout support (read_timeout, open_timeout, write_timeout)
#
# Fork Reference: Commits cdc6067, 3daa4fb

module RubyLLM
  class Connection
    class << self
      # Override basic to use net_http adapter
      # This avoids async-http SSL/IPv6 issues for simple API calls
      def basic(&)
        Faraday.new do |f|
          f.response(
            :logger,
            RubyLLM.logger,
            bodies: false,
            response: false,
            errors: true,
            headers: false,
            log_level: :debug,
          )
          f.response(:raise_error)
          yield f if block_given?
          # Use net_http for simple API calls to avoid async-http SSL/IPv6 issues
          f.adapter(:net_http)
        end
      end
    end

    private

    # Override setup_timeout to support granular timeouts
    def setup_timeout(faraday)
      faraday.options.timeout = @config.request_timeout
      faraday.options.open_timeout = @config.open_timeout if @config.respond_to?(:open_timeout) && @config.open_timeout
      faraday.options.write_timeout = @config.write_timeout if @config.respond_to?(:write_timeout) && @config.write_timeout

      # read_timeout defaults to request_timeout for streaming support
      if @config.respond_to?(:read_timeout)
        faraday.options.read_timeout = @config.read_timeout || @config.request_timeout
      end
    end
  end
end
