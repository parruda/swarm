# frozen_string_literal: true

module SwarmSDK
  module Tools
    # WebFetch tool for fetching and processing web content
    #
    # Fetches content from URLs, converts HTML to markdown, and processes it
    # using an AI model to extract information based on a provided prompt.
    class WebFetch < RubyLLM::Tool
      def initialize
        super()
        @cache = {}
        @cache_ttl = 900 # 15 minutes in seconds
        @llm_enabled = SwarmSDK.settings.webfetch_llm_enabled?
      end

      def name
        "WebFetch"
      end

      description <<~DESC
        - Fetches content from a specified URL and converts it to markdown
        - Optionally processes the content with an LLM if configured
        - Fetches the URL content, converts HTML to markdown
        - Returns markdown content or LLM analysis (based on configuration)
        - Use this tool when you need to retrieve and analyze web content

        Usage notes:
          - IMPORTANT: If an MCP-provided web fetch tool is available, prefer using that tool instead of this one, as it may have fewer restrictions. All MCP-provided tools start with "mcp__".
          - The URL must be a fully-formed valid URL
          - HTTP URLs will be automatically upgraded to HTTPS
          - This tool is read-only and does not modify any files
          - Content will be truncated if very large
          - Includes a self-cleaning 15-minute cache for faster responses
          - When a URL redirects to a different host, the tool will inform you and provide the redirect URL in a special format. You should then make a new WebFetch request with the redirect URL to fetch the content.

        LLM Processing:
          - When SwarmSDK is configured with webfetch_provider and webfetch_model, the 'prompt' parameter is required
          - The tool will process the markdown content with the configured LLM using your prompt
          - Without this configuration, the tool returns raw markdown and the 'prompt' parameter is optional (ignored if provided)
          - Configure with: SwarmSDK.configure { |c| c.webfetch_provider = "anthropic"; c.webfetch_model = "claude-3-5-haiku-20241022" }
      DESC

      param :url,
        type: "string",
        desc: "The URL to fetch content from",
        required: true

      param :prompt,
        type: "string",
        desc: "The prompt to run on the fetched content. Required when SwarmSDK is configured with webfetch_provider and webfetch_model. Optional otherwise (ignored if LLM processing not configured).",
        required: false

      # Backward compatibility aliases - use Defaults module for new code
      MAX_CONTENT_LENGTH = Defaults::Limits::WEB_FETCH_CHARACTERS
      USER_AGENT = "SwarmSDK WebFetch Tool (https://github.com/parruda/claude-swarm)"
      TIMEOUT = Defaults::Timeouts::WEB_FETCH_SECONDS

      def execute(url:, prompt: nil)
        # Validate inputs
        return validation_error("url is required") if url.nil? || url.empty?

        # Validate prompt when LLM processing is enabled
        if @llm_enabled && (prompt.nil? || prompt.empty?)
          return validation_error("prompt is required when LLM processing is configured")
        end

        # Validate and normalize URL
        normalized_url = normalize_url(url)
        return validation_error("Invalid URL format: #{url}") unless normalized_url

        # Check cache first (cache key includes prompt if LLM is enabled)
        cache_key = @llm_enabled ? "#{normalized_url}:#{prompt}" : normalized_url
        cached = get_from_cache(cache_key)
        return cached if cached

        # Fetch the URL
        fetch_result = fetch_url(normalized_url)
        return fetch_result if fetch_result.is_a?(String) && fetch_result.start_with?("Error")

        # Check for redirects to different hosts
        if fetch_result[:redirect_url] && different_host?(normalized_url, fetch_result[:redirect_url])
          return format_redirect_message(fetch_result[:redirect_url])
        end

        # Convert HTML to markdown
        markdown_content = html_to_markdown(fetch_result[:body])

        # Truncate if too long
        if markdown_content.length > MAX_CONTENT_LENGTH
          markdown_content = markdown_content[0...MAX_CONTENT_LENGTH]
          markdown_content += "\n\n[Content truncated due to length]"
        end

        # Process with AI model if LLM is enabled, otherwise return markdown
        result = if @llm_enabled
          process_with_llm(markdown_content, prompt, normalized_url)
        else
          markdown_content
        end

        # Cache the result
        store_in_cache(cache_key, result)

        result
      rescue StandardError => e
        error("Unexpected error fetching URL: #{e.class.name} - #{e.message}")
      end

      private

      def validation_error(message)
        "<tool_use_error>InputValidationError: #{message}</tool_use_error>"
      end

      def error(message)
        "Error: #{message}"
      end

      def normalize_url(url)
        # Upgrade HTTP to HTTPS
        url = url.sub(%r{^http://}, "https://")

        # Validate URL format
        uri = URI.parse(url)
        return unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        return unless uri.host

        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def different_host?(url1, url2)
        uri1 = URI.parse(url1)
        uri2 = URI.parse(url2)
        uri1.host != uri2.host
      rescue URI::InvalidURIError
        false
      end

      def fetch_url(url)
        require "faraday"
        require "faraday/follow_redirects"

        response = Faraday.new(url: url) do |conn|
          conn.request(:url_encoded)
          conn.response(:follow_redirects, limit: 5)
          conn.adapter(Faraday.default_adapter)
          conn.options.timeout = TIMEOUT
          conn.options.open_timeout = TIMEOUT
        end.get do |req|
          req.headers["User-Agent"] = USER_AGENT
          req.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        end

        unless response.success?
          return error("HTTP #{response.status}: Failed to fetch URL")
        end

        # Check final URL for redirects
        final_url = response.env.url.to_s
        redirect_url = final_url if final_url != url

        {
          body: response.body,
          redirect_url: redirect_url,
        }
      rescue Faraday::TimeoutError
        error("Request timed out after #{TIMEOUT} seconds")
      rescue Faraday::ConnectionFailed => e
        error("Connection failed: #{e.message}")
      rescue StandardError => e
        error("Failed to fetch URL: #{e.class.name} - #{e.message}")
      end

      def html_to_markdown(html)
        # Use HtmlConverter to handle conversion with optional reverse_markdown gem
        converter = DocumentConverters::HtmlConverter.new
        converter.convert_string(html)
      end

      def process_with_llm(content, prompt, url)
        # Use configured model for processing
        # Format the prompt to include the content
        full_prompt = <<~PROMPT
          You are analyzing content from the URL: #{url}

          User request: #{prompt}

          Content:
          #{content}

          Please respond to the user's request based on the content above.
        PROMPT

        # Get settings
        config = SwarmSDK.settings

        # Build chat with configured provider and model
        chat_params = {
          model: config.webfetch_model,
          provider: config.webfetch_provider.to_sym,
        }
        chat_params[:base_url] = config.webfetch_base_url if config.webfetch_base_url

        chat = RubyLLM.chat(**chat_params).with_params(max_tokens: config.webfetch_max_tokens)

        response = chat.ask(full_prompt)

        # Extract the text response
        response_text = response.content
        return error("Failed to process content with LLM: No response text") unless response_text

        response_text
      rescue StandardError => e
        error("Failed to process content with LLM: #{e.class.name} - #{e.message}")
      end

      def format_redirect_message(redirect_url)
        <<~MESSAGE
          This URL redirected to a different host.

          Redirect URL: #{redirect_url}

          <system-reminder>
          The requested URL redirected to a different host. To fetch the content from the redirect URL,
          make a new WebFetch request with the redirect URL provided above.
          </system-reminder>
        MESSAGE
      end

      def get_from_cache(key)
        entry = @cache[key]
        return unless entry

        # Check if cache entry is still valid
        if Time.now.to_i - entry[:timestamp] > @cache_ttl
          @cache.delete(key)
          return
        end

        entry[:value]
      end

      def store_in_cache(key, value)
        # Clean old cache entries
        clean_cache

        @cache[key] = {
          value: value,
          timestamp: Time.now.to_i,
        }
      end

      def clean_cache
        now = Time.now.to_i
        @cache.delete_if { |_key, entry| now - entry[:timestamp] > @cache_ttl }
      end
    end
  end
end
