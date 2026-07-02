require "net/http"
require "json"

module AI
  class Translator
    def self.call(text:, source_language:, target_language:, context: nil)
      new(text: text, source_language: source_language, target_language: target_language, context: context).call
    end

    def initialize(text:, source_language:, target_language:, context:)
      @text = text.to_s
      @source_language = LanguageHelper.normalize_code(source_language)
      @target_language = LanguageHelper.normalize_code(target_language)
      @context = context
    end

    def call
      return @text if @text.blank?
      return @text if @source_language.present? && @source_language == @target_language
      return @text if ENV["AI_SERVICE_URL"].blank?

      response = Net::HTTP.post(
        translate_uri,
        payload.to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )
      return @text unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body).fetch("translated_text").presence || @text
    rescue StandardError => error
      Rails.logger.warn("[ai-translate] fallback #{error.class}: #{error.message}")
      @text
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
  end
end
