# frozen_string_literal: true

# Monkey-patch io-endpoint to handle EHOSTUNREACH (IPv6 unreachable)
# This fixes an issue where the async adapter fails on IPv6 without trying IPv4
#
# Fork Reference: Commit cdc6067

begin
  require "io/endpoint"
  require "io/endpoint/host_endpoint"

  # rubocop:disable Style/ClassAndModuleChildren
  # Reopen the existing class (no superclass specified)
  class IO::Endpoint::HostEndpoint
    # Override connect to add EHOSTUNREACH to the rescue list
    # This allows the connection to fall back to IPv4 when IPv6 is unavailable
    def connect(wrapper = self.wrapper, &block)
      last_error = nil

      Addrinfo.foreach(*@specification) do |address|
        socket = wrapper.connect(address, **@options)
      rescue Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH, Errno::EAGAIN => last_error
        # Try next address (IPv4 fallback)
      else
        return socket unless block_given?

        begin
          return yield(socket)
        ensure
          socket.close
        end
      end

      raise last_error if last_error
    end
  end
  # rubocop:enable Style/ClassAndModuleChildren
rescue LoadError
  # io-endpoint gem not available, skip this patch
end
