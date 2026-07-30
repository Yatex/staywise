require "net/http"
require "json"

module Translation
  class AIServiceProvider < Provider
    def translate_messages(messages:, target_language:, source_language: "auto", context: nil)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return failure("AI_SERVICE_URL is not configured", started_at) if ENV["AI_SERVICE_URL"].blank?

      response = Net::HTTP.post(
        URI.join(ENV.fetch("AI_SERVICE_URL"), "/translate/messages"),
        {
          source_language: source_language,
          target_language: target_language,
          context: context,
          messages: messages
        }.compact.to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )
      return failure("Translation service returned HTTP #{response.code}", started_at) unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      Result.new(
        success?: true,
        translations: Array(parsed["translations"]),
        provider: "ai_service",
        model: parsed.dig("audit", "model"),
        error: nil,
        duration_ms: duration_since(started_at)
      )
    rescue StandardError => error
      failure("#{error.class}: #{error.message}", started_at)
    end

    private

    def failure(error, started_at)
      Result.new(success?: false, translations: [], provider: "ai_service", model: nil,
        error: error, duration_ms: duration_since(started_at))
    end

    def duration_since(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round
    end
  end

  AiServiceProvider = AIServiceProvider
end
