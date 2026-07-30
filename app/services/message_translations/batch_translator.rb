module MessageTranslations
  class BatchTranslator
    Result = Struct.new(:success?, :translated_count, :reused_count, :error, keyword_init: true)

    def self.call(messages:, target_language:, context: nil, provider: nil)
      new(messages: messages, target_language: target_language, context: context, provider: provider).call
    end

    def initialize(messages:, target_language:, context:, provider:)
      @messages = messages
      @target_language = AI::LanguageHelper.normalize_code(target_language)
      @context = context
      @provider = provider
    end

    def call
      candidates = @messages.select { |message| candidate?(message) }
      reused = @messages.size - candidates.size
      return Result.new(success?: true, translated_count: 0, reused_count: reused) if candidates.empty?

      payload = candidates.map { |message| { id: message.id, body: message.body } }
      candidates_by_id = candidates.index_by { |message| message.id.to_s }
      results = if @provider
        Translation::Service.translate_messages(messages: payload, target_language: @target_language,
          context: @context, primary: @provider)
      else
        Translation::Service.translate_messages(messages: payload, target_language: @target_language, context: @context)
      end

      translated = 0
      errors = []
      returned_ids = []
      results.each do |result|
        unless result.success?
          errors << result.error
          next
        end
        Array(result.translations).each do |item|
          message = candidates_by_id[item["id"].to_s]
          next unless message
          returned_ids << message.id.to_s
          integrity = IntegrityChecker.call(original: message.body, translated: item["translated_body"])
          unless integrity[:valid]
            errors << "protected_values_changed:#{message.id}"
            next
          end
          translation = message.message_translations.find_or_initialize_by(target_language: @target_language)
          translation.update!(
            translated_body: item["translated_body"],
            source_language: AI::LanguageHelper.normalize_code(item["source_language"]),
            provider: result.provider,
            model: result.model,
            status: "completed",
            error_message: nil
          )
          message.update_column(:detected_language, translation.source_language) if message.detected_language.blank?
          translated += 1
        end
      end
      missing_ids = candidates_by_id.keys - returned_ids
      errors.concat(missing_ids.map { |id| "translation_missing:#{id}" })
      providers = results.map(&:provider).compact.uniq.join(",")
      duration_ms = results.sum { |result| result.duration_ms.to_i }
      Rails.logger.info(
        "[conversation-translation] messages=#{@messages.size} characters=#{payload.sum { |item| item[:body].length }} " \
        "provider=#{providers.presence || "unknown"} duration_ms=#{duration_ms} new=#{translated} reused=#{reused} " \
        "success=#{errors.empty?}"
      )
      Result.new(success?: errors.empty?, translated_count: translated, reused_count: reused, error: errors.join(", ").presence)
    end

    private

    def candidate?(message)
      return false if message.body.blank?
      return false if AI::LanguageHelper.normalize_code(message.detected_language) == @target_language

      message.translation_for(@target_language).blank?
    end
  end
end
