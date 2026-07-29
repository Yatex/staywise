module Translation
  class Provider
    Result = Struct.new(:success?, :translations, :provider, :model, :error, :duration_ms, keyword_init: true)

    def translate_messages(messages:, target_language:, source_language: "auto", context: nil)
      raise NotImplementedError
    end

    def translate_text(text:, target_language:, source_language: "auto", context: nil)
      result = translate_messages(
        messages: [{ id: "text", body: text }],
        target_language: target_language,
        source_language: source_language,
        context: context
      )
      translation = result.translations.to_a.first
      Result.new(
        success?: result.success? && translation.present?,
        translations: translation,
        provider: result.provider,
        model: result.model,
        error: result.error,
        duration_ms: result.duration_ms
      )
    end
  end
end
