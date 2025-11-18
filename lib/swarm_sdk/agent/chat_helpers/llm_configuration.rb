# frozen_string_literal: true

module SwarmSDK
  module Agent
    module ChatHelpers
      # LLM configuration and provider setup
      #
      # Extracted from Chat to reduce class size and centralize RubyLLM setup logic.
      module LlmConfiguration
        private

        # Create the internal RubyLLM::Chat instance
        #
        # @return [RubyLLM::Chat] Chat instance
        def create_llm_chat(model_id:, provider_name:, base_url:, api_version:, timeout:, assume_model_exists:, max_concurrent_tools:)
          chat_options = build_chat_options(max_concurrent_tools)

          chat = instantiate_chat(
            model_id: model_id,
            provider_name: provider_name,
            base_url: base_url,
            timeout: timeout,
            assume_model_exists: assume_model_exists,
            chat_options: chat_options,
          )

          # Enable RubyLLM's native Responses API if configured
          enable_responses_api(chat, api_version, base_url) if api_version == "v1/responses"

          chat
        end

        # Build chat options hash
        #
        # @param max_concurrent_tools [Integer, nil] Max concurrent tool executions
        # @return [Hash] Chat options
        def build_chat_options(max_concurrent_tools)
          return {} unless max_concurrent_tools

          {
            tool_concurrency: :async,
            max_concurrency: max_concurrent_tools,
          }
        end

        # Instantiate RubyLLM::Chat with appropriate configuration
        #
        # @return [RubyLLM::Chat] Chat instance
        def instantiate_chat(model_id:, provider_name:, base_url:, timeout:, assume_model_exists:, chat_options:)
          if base_url || timeout != Defaults::Timeouts::AGENT_REQUEST_SECONDS
            instantiate_with_custom_context(
              model_id: model_id,
              provider_name: provider_name,
              base_url: base_url,
              timeout: timeout,
              assume_model_exists: assume_model_exists,
              chat_options: chat_options,
            )
          elsif provider_name
            instantiate_with_provider(
              model_id: model_id,
              provider_name: provider_name,
              assume_model_exists: assume_model_exists,
              chat_options: chat_options,
            )
          else
            instantiate_default(
              model_id: model_id,
              assume_model_exists: assume_model_exists,
              chat_options: chat_options,
            )
          end
        end

        # Instantiate chat with custom context (base_url/timeout overrides)
        def instantiate_with_custom_context(model_id:, provider_name:, base_url:, timeout:, assume_model_exists:, chat_options:)
          raise ArgumentError, "Provider must be specified when base_url is set" if base_url && !provider_name

          context = build_custom_context(provider: provider_name, base_url: base_url, timeout: timeout)
          assume_model_exists = base_url ? true : false if assume_model_exists.nil?

          RubyLLM.chat(
            model: model_id,
            provider: provider_name,
            assume_model_exists: assume_model_exists,
            context: context,
            **chat_options,
          )
        end

        # Instantiate chat with explicit provider
        def instantiate_with_provider(model_id:, provider_name:, assume_model_exists:, chat_options:)
          assume_model_exists = false if assume_model_exists.nil?

          RubyLLM.chat(
            model: model_id,
            provider: provider_name,
            assume_model_exists: assume_model_exists,
            **chat_options,
          )
        end

        # Instantiate chat with default configuration
        def instantiate_default(model_id:, assume_model_exists:, chat_options:)
          assume_model_exists = false if assume_model_exists.nil?

          RubyLLM.chat(
            model: model_id,
            assume_model_exists: assume_model_exists,
            **chat_options,
          )
        end

        # Build custom RubyLLM context for base_url/timeout overrides
        #
        # @return [RubyLLM::Context] Configured context
        def build_custom_context(provider:, base_url:, timeout:)
          RubyLLM.context do |config|
            config.request_timeout = timeout

            configure_provider_base_url(config, provider, base_url) if base_url
          end
        end

        # Configure provider-specific base URL
        def configure_provider_base_url(config, provider, base_url)
          case provider.to_s
          when "openai", "deepseek", "perplexity", "mistral", "openrouter"
            config.openai_api_base = base_url
            config.openai_api_key = ENV["OPENAI_API_KEY"] || "dummy-key-for-local"
            config.openai_use_system_role = true
          when "ollama"
            config.ollama_api_base = base_url
          when "gpustack"
            config.gpustack_api_base = base_url
            config.gpustack_api_key = ENV["GPUSTACK_API_KEY"] || "dummy-key"
          else
            raise ArgumentError, "Provider '#{provider}' doesn't support custom base_url."
          end
        end

        # Fetch real model info for accurate context tracking
        #
        # @param model_id [String] Model ID to lookup
        def fetch_real_model_info(model_id)
          @model_lookup_error = nil
          @real_model_info = begin
            RubyLLM.models.find(model_id)
          rescue StandardError => e
            suggestions = suggest_similar_models(model_id)
            @model_lookup_error = {
              model: model_id,
              error_message: e.message,
              suggestions: suggestions,
            }
            nil
          end
        end

        # Enable RubyLLM's native Responses API on the chat instance
        #
        # Uses RubyLLM's built-in support for OpenAI's Responses API (v1/responses endpoint)
        # which provides automatic stateful conversation tracking with 5-minute TTL.
        #
        # @param chat [RubyLLM::Chat] Chat instance to configure
        # @param api_version [String] API version (should be "v1/responses")
        # @param base_url [String, nil] Custom endpoint URL if any
        def enable_responses_api(chat, api_version, base_url)
          return unless api_version == "v1/responses"

          # Warn if using custom endpoint (typically doesn't support Responses API)
          if base_url && !base_url.include?("api.openai.com")
            RubyLLM.logger.warn(
              "SwarmSDK: Responses API requested but using custom endpoint #{base_url}. " \
                "Custom endpoints typically don't support /v1/responses.",
            )
          end

          # Enable native RubyLLM Responses API support
          # - stateful: true enables automatic previous_response_id tracking
          # - store: true enables server-side conversation storage
          chat.with_responses_api(stateful: true, store: true)
          RubyLLM.logger.debug("SwarmSDK: Enabled native Responses API support")
        end

        # Configure LLM parameters with proper temperature normalization
        #
        # @param params [Hash] Parameter hash
        # @return [self]
        def configure_parameters(params)
          return self if params.nil? || params.empty?

          if params[:temperature]
            @llm_chat.with_temperature(params[:temperature])
            params = params.except(:temperature)
          end

          @llm_chat.with_params(**params) if params.any?

          self
        end

        # Configure custom HTTP headers for LLM requests
        #
        # @param headers [Hash, nil] Custom HTTP headers
        # @return [self]
        def configure_headers(custom_headers)
          return self if custom_headers.nil? || custom_headers.empty?

          @llm_chat.with_headers(**custom_headers)

          self
        end

        # Suggest similar models when a model is not found
        #
        # @param query [String] Model name to search for
        # @return [Array<RubyLLM::Model::Info>] Up to 3 similar models
        def suggest_similar_models(query)
          normalized_query = query.to_s.downcase.gsub(/[.\-_]/, "")

          RubyLLM.models.all.select do |model_info|
            normalized_id = model_info.id.downcase.gsub(/[.\-_]/, "")
            normalized_id.include?(normalized_query) ||
              model_info.name&.downcase&.gsub(/[.\-_]/, "")&.include?(normalized_query)
          end.first(3)
        rescue StandardError
          []
        end
      end
    end
  end
end
