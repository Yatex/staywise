module Translation
  class Service
    MAX_MESSAGES = 50
    MAX_CHARACTERS = 30_000

    def self.translate_messages(messages:, target_language:, source_language: "auto", context: nil,
      primary: nil, fallback: nil)
      new(primary: primary, fallback: fallback).translate_messages(
        messages: messages, target_language: target_language,
        source_language: source_language, context: context
      )
    end

    def self.translate_text(text:, target_language:, source_language: "auto", context: nil,
      primary: nil, fallback: nil)
      new(primary: primary, fallback: fallback).translate_text(
        text: text, target_language: target_language,
        source_language: source_language, context: context
      )
    end

    def initialize(primary:, fallback:)
      @primary = primary || ProviderFactory.build
      @fallback = fallback
    end

    def translate_messages(messages:, target_language:, source_language:, context:)
      batches(messages).map do |batch|
        result = @primary.translate_messages(messages: batch, target_language: target_language,
          source_language: source_language, context: context)
        result = @fallback.translate_messages(messages: batch, target_language: target_language,
          source_language: source_language, context: context) if !result.success? && @fallback
        result
      end
    end

    def translate_text(text:, target_language:, source_language:, context:)
      result = @primary.translate_text(text: text, target_language: target_language,
        source_language: source_language, context: context)
      return result if result.success? || @fallback.blank?

      @fallback.translate_text(text: text, target_language: target_language,
        source_language: source_language, context: context)
    end

    private

    def batches(messages)
      messages.each_with_object([[]]) do |message, groups|
        current = groups.last
        projected_size = current.sum { |item| item[:body].to_s.length } + message[:body].to_s.length
        groups << [] if current.size >= MAX_MESSAGES || (current.any? && projected_size > MAX_CHARACTERS)
        groups.last << message
      end.reject(&:empty?)
    end
  end
end
