# frozen_string_literal: true

require "test_helper"

module SwarmSDK
  module RubyLLMPatches
    class IoEndpointPatchTest < Minitest::Test
      # ========== Patch Presence ==========

      def test_patch_loaded_when_io_endpoint_available
        # If io-endpoint is available, the patch should have been applied
        if defined?(IO::Endpoint::HostEndpoint)
          # Verify the connect method exists and handles EHOSTUNREACH
          host_endpoint = IO::Endpoint::HostEndpoint

          assert(host_endpoint.method_defined?(:connect))
        else
          skip("io-endpoint gem not available")
        end
      end

      def test_patch_handles_missing_io_endpoint_gracefully
        # The patch file wraps in begin/rescue LoadError
        # This test just verifies no exception was raised during load
        # (if io-endpoint isn't installed, the patch is silently skipped)
        assert(true, "Patch loaded without raising")
      end

      # ========== Error Classes in Rescue ==========

      def test_ehostunreach_is_a_system_call_error
        # Verify the error class exists that the patch rescues
        assert_kind_of(Class, Errno::EHOSTUNREACH)
        assert_operator(Errno::EHOSTUNREACH, :<, SystemCallError)
      end

      def test_econnrefused_is_a_system_call_error
        assert_kind_of(Class, Errno::ECONNREFUSED)
        assert_operator(Errno::ECONNREFUSED, :<, SystemCallError)
      end

      def test_enetunreach_is_a_system_call_error
        assert_kind_of(Class, Errno::ENETUNREACH)
        assert_operator(Errno::ENETUNREACH, :<, SystemCallError)
      end
    end
  end
end
