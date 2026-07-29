module MessageTranslations
  class IntegrityChecker
    URL_PATTERN = %r{https?://[^\s<>"']+}.freeze
    PHONE_PATTERN = /(?<!\w)\+?\d[\d\s().-]{6,}\d/.freeze
    NUMBER_OR_SEQUENCE_PATTERN = %r{(?<!\w)\d+(?:[.:,/-]\d+)*(?:[#*])?(?!\w)}.freeze

    def self.call(original:, translated:)
      original_tokens = [
        original.to_s.scan(URL_PATTERN),
        original.to_s.scan(PHONE_PATTERN),
        original.to_s.scan(NUMBER_OR_SEQUENCE_PATTERN)
      ].flatten.map(&:strip).uniq

      missing = original_tokens.reject { |token| translated.to_s.include?(token) }
      { valid: missing.empty?, missing_tokens: missing }
    end
  end
end
