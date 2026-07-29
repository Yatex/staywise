module Translation
  class ReplyDraftTranslator
    def self.call(draft:, provider: nil)
      result = Service.translate_text(
        text: draft.original_body,
        source_language: draft.source_language.presence || "auto",
        target_language: draft.target_language,
        context: "Translate a host reply for a short-term rental guest. Do not add information.",
        **(provider ? { primary: provider } : {})
      )
      translation = result.translations
      unless result.success? && translation.present?
        draft.update!(translation_status: "failed", error_message: result.error)
        return false
      end
      body = translation["translated_body"]
      integrity = MessageTranslations::IntegrityChecker.call(original: draft.original_body, translated: body)
      unless integrity[:valid]
        draft.update!(translation_status: "failed", error_message: "Translation changed protected operational values")
        return false
      end
      draft.update!(
        translated_body: body,
        source_language: AI::LanguageHelper.normalize_code(translation["source_language"]),
        translation_provider: result.provider,
        translation_model: result.model,
        translation_status: "completed",
        error_message: nil
      )
      true
    end
  end
end
