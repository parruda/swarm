# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # LLM instrumentation for API request/response logging
      #
      # Extracted from Chat to reduce class size and centralize observability logic.
      module Instrumentation
        private

        # Inject LLM instrumentation middleware for API request/response logging
        #
        # @return [void]
        def inject_llm_instrumentation
          return unless @provider

          faraday_conn = @provider.connection&.connection
          return unless faraday_conn
          return if @llm_instrumentation_injected

          provider_name = @provider.class.name.split("::").last.downcase

          faraday_conn.builder.insert(
            0,
            SwarmSDK::Agent::LLMInstrumentationMiddleware,
            on_request: method(:handle_llm_api_request),
            on_response: method(:handle_llm_api_response),
            provider_name: provider_name,
          )

          @llm_instrumentation_injected = true

          RubyLLM.logger.debug("SwarmSDK: Injected LLM instrumentation middleware for agent #{@agent_name}")
        rescue StandardError => e
          RubyLLM.logger.error("SwarmSDK: Failed to inject LLM instrumentation: #{e.message}")
        end

        # Handle LLM API request event
        #
        # @param data [Hash] Request data from middleware
        def handle_llm_api_request(data)
          return unless LogStream.emitter

          LogStream.emit(
            type: "llm_api_request",
            agent: @agent_name,
            swarm_id: @agent_context&.swarm_id,
            parent_swarm_id: @agent_context&.parent_swarm_id,
            **data,
          )
        rescue StandardError => e
          RubyLLM.logger.error("SwarmSDK: Error emitting llm_api_request event: #{e.message}")
        end

        # Handle LLM API response event
        #
        # @param data [Hash] Response data from middleware
        def handle_llm_api_response(data)
          return unless LogStream.emitter

          LogStream.emit(
            type: "llm_api_response",
            agent: @agent_name,
            swarm_id: @agent_context&.swarm_id,
            parent_swarm_id: @agent_context&.parent_swarm_id,
            **data,
          )
        rescue StandardError => e
          RubyLLM.logger.error("SwarmSDK: Error emitting llm_api_response event: #{e.message}")
        end
      end
    end
  end
end
