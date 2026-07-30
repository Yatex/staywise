require "net/http"
require "json"

module AI
  class Translator
    Result = Struct.new(:success?, :text, :source_language, :provider, :model, :error, keyword_init: true)

    def self.call(text:, source_language:, target_language:, context: nil)
      new(text: text, source_language: source_language, target_language: target_language, context: context).call
    end

    def self.translate(text:, source_language:, target_language:, context: nil)
      new(text: text, source_language: source_language, target_language: target_language, context: context).translate
    end

    def initialize(text:, source_language:, target_language:, context:)
      @text = text.to_s
      @source_language = LanguageHelper.normalize_code(source_language)
      @target_language = LanguageHelper.normalize_code(target_language)
      @context = context
    end

    def call
      result = translate
      result.success? ? result.text : @text
    end

    def translate
      return success(@text, source_language: @source_language) if @text.blank?
      return success(@text, source_language: @source_language) if @source_language.present? && @source_language == @target_language
      return failure("AI_SERVICE_URL is not configured") if ENV["AI_SERVICE_URL"].blank?

      response = Net::HTTP.post(
        translate_uri,
        payload.to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )
      return failure("AI service returned HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      translated_text = parsed.fetch("translated_text").presence
      return failure("AI service returned an empty translation") if translated_text.blank?

      success(
        translated_text,
        source_language: LanguageHelper.normalize_code(parsed["source_language"]).presence || @source_language,
        provider: parsed.dig("audit", "provider").presence || "ai_service",
        model: parsed.dig("audit", "model")
      )
    rescue StandardError => error
      Rails.logger.warn("[ai-translate] fallback #{error.class}: #{error.message}")
      failure("#{error.class}: #{error.message}")
    end

    private

    def translate_uri
      URI.join(ENV.fetch("AI_SERVICE_URL"), "/translate")
    end

    def payload
      {
        text: @text,
        source_language: @source_language,
        target_language: @target_language.presence || "es",
        context: @context
      }.compact
    end

    def success(text, source_language:, provider: nil, model: nil)
      Result.new(success?: true, text: text, source_language: source_language, provider: provider, model: model, error: nil)
    end

    def failure(error)
      Result.new(success?: false, text: @text, source_language: @source_language, provider: "ai_service", model: nil, error: error)
    end
  end
end
