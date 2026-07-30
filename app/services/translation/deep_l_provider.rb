require "net/http"
require "json"

module Translation
  class DeepLProvider < Provider
    DEFAULT_OPEN_TIMEOUT_SECONDS = 3
    DEFAULT_READ_TIMEOUT_SECONDS = 15
    TARGET_LANGUAGES = {
      "es" => "ES",
      "en" => "EN"
    }.freeze

    def translate_messages(messages:, target_language:, source_language: "auto", context: nil)
      started_at = monotonic_now
      failure_options = {
        operation: "batch",
        texts: [],
        source_language: source_language,
        target_language: target_language
      }
      texts = Array(messages).filter_map do |message|
        body = message[:body].to_s
        next if body.blank?

        { id: message[:id], body: body }
      end
      failure_options = {
        operation: operation_for(texts),
        texts: texts,
        source_language: source_language,
        target_language: target_language
      }
      return failure("DEEPL_EMPTY_BATCH", started_at, **failure_options) if texts.empty?
      return failure("DEEPL_API_KEY_MISSING", started_at, **failure_options) if api_key.blank?
      return failure("DEEPL_API_BASE_URL_MISSING", started_at, **failure_options) if base_url.blank?

      target = TARGET_LANGUAGES[AI::LanguageHelper.normalize_code(target_language)]
      return failure("DEEPL_TARGET_LANGUAGE_UNSUPPORTED", started_at, **failure_options) if target.blank?

      request_body = {
        text: texts.map { |item| item[:body] },
        target_lang: target
      }
      normalized_source = AI::LanguageHelper.normalize_code(source_language)
      request_body[:source_lang] = normalized_source.upcase if normalized_source.present? && normalized_source != "auto"
      request_body[:context] = context.to_s.first(2_000) if context.present?

      response = perform_request(request_body)
      unless response.is_a?(Net::HTTPSuccess)
        return failure("DEEPL_HTTP_#{response.code}", started_at, **failure_options)
      end

      parsed = JSON.parse(response.body)
      translations = Array(parsed["translations"])
      unless translations.size == texts.size
        return failure("DEEPL_RESULT_COUNT_MISMATCH", started_at, **failure_options)
      end

      mapped = texts.each_with_index.map do |item, index|
        translation = translations.fetch(index)
        {
          "id" => item[:id],
          "source_language" => AI::LanguageHelper.normalize_code(translation["detected_source_language"]).to_s.downcase,
          "target_language" => AI::LanguageHelper.normalize_code(target_language),
          "translated_body" => translation["text"].to_s
        }
      end
      unless mapped.all? { |translation| translation["translated_body"].present? }
        return failure("DEEPL_EMPTY_TRANSLATION", started_at, **failure_options)
      end

      success(mapped, started_at, operation: operation_for(texts), character_count: texts.sum { |item| item[:body].length },
        source_language: normalized_source, target_language: target_language)
    rescue Net::OpenTimeout
      failure("DEEPL_OPEN_TIMEOUT", started_at, **failure_options)
    rescue Net::ReadTimeout
      failure("DEEPL_READ_TIMEOUT", started_at, **failure_options)
    rescue JSON::ParserError
      failure("DEEPL_INVALID_RESPONSE", started_at, **failure_options)
    rescue URI::InvalidURIError
      failure("DEEPL_API_BASE_URL_INVALID", started_at, **failure_options)
    rescue StandardError => error
      Rails.logger.warn("[translation-provider] provider=deepl status=failure error_code=DEEPL_NETWORK_ERROR error_class=#{error.class.name}")
      failure("DEEPL_NETWORK_ERROR", started_at, **failure_options)
    end

    private

    def perform_request(request_body)
      uri = URI.join(normalized_base_url, "v2/translate")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "DeepL-Auth-Key #{api_key}"
      request["Content-Type"] = "application/json"
      request.body = request_body.to_json

      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: ENV.fetch("DEEPL_OPEN_TIMEOUT_SECONDS", DEFAULT_OPEN_TIMEOUT_SECONDS).to_i,
        read_timeout: ENV.fetch("DEEPL_READ_TIMEOUT_SECONDS", DEFAULT_READ_TIMEOUT_SECONDS).to_i
      ) { |http| http.request(request) }
    end

    def api_key
      ENV["DEEPL_API_KEY"].to_s.strip
    end

    def base_url
      ENV["DEEPL_API_BASE_URL"].to_s.strip
    end

    def normalized_base_url
      base_url.end_with?("/") ? base_url : "#{base_url}/"
    end

    def operation_for(texts)
      texts.size == 1 ? "individual" : "batch"
    end

    def success(translations, started_at, operation:, character_count:, source_language:, target_language:)
      duration_ms = duration_since(started_at)
      log_metrics(operation: operation, count: translations.size, character_count: character_count,
        source_language: source_language, target_language: target_language, duration_ms: duration_ms, status: "success")
      Result.new(success?: true, translations: translations, provider: "deepl", model: nil,
        error: nil, duration_ms: duration_ms)
    end

    def failure(error_code, started_at, operation:, texts: [], source_language: nil, target_language: nil)
      duration_ms = duration_since(started_at)
      log_metrics(operation: operation, count: texts.size,
        character_count: texts.sum { |item| item[:body].to_s.length }, source_language: source_language,
        target_language: target_language, duration_ms: duration_ms, status: "failure", error_code: error_code)
      Result.new(success?: false, translations: [], provider: "deepl", model: nil,
        error: error_code, duration_ms: duration_ms)
    end

    def log_metrics(operation:, count:, character_count:, source_language:, target_language:, duration_ms:, status:, error_code: nil)
      Rails.logger.info(
        "[translation-provider] provider=deepl operation=#{operation} messages=#{count} characters=#{character_count} " \
        "source_language=#{source_language.presence || "auto"} target_language=#{target_language.presence || "unknown"} " \
        "duration_ms=#{duration_ms} status=#{status} error_code=#{error_code.presence || "none"}"
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def duration_since(started_at)
      ((monotonic_now - started_at) * 1_000).round
    end
  end
end
