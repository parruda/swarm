# frozen_string_literal: true

# rubocop/no_reflection_methods.rb

require "rubocop"

module RuboCop
  module Cop
    module Security
      # Custom cop to catch reflection methods that break encapsulation
      #
      # This cop prevents use of:
      # - instance_variable_get
      # - instance_variable_set
      # - send (dynamic method calls)
      #
      # These methods break encapsulation and make code harder to understand and maintain.
      class NoReflectionMethods < Base
        MSG = "Do not use `%<method>s`; it uses reflection and can break encapsulation."
        TEST_MSG = "Do not use `%<method>s`; it uses reflection and can break encapsulation. " \
          "You must test behaviour through calling public methods. " \
          "Private methods must be tested through calls done to public methods." \
          "CRITICAL: DO NOT disable this cop."

        # Match method calls
        def on_send(node)
          banned_methods = [:instance_variable_get, :instance_variable_set, :send, :const_set, :const_get]

          method_name = node.method_name
          return unless banned_methods.include?(method_name)

          # Check if we're in a test file
          file_path = processed_source.file_path
          in_test_file = file_path.end_with?("_test.rb")

          message = if in_test_file
            format(TEST_MSG, method: method_name)
          else
            format(MSG, method: method_name)
          end

          add_offense(node.loc.selector, message: message)
        end
      end
    end
  end
end
