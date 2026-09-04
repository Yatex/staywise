module Copilot
  class ResponseContract
    class InvalidResponse < StandardError; end

    ATTRIBUTES = %w[
      detected_language guest_question_es answer_summary_es guest_reply confidence
      missing_information clarifying_question_es clarifying_question_guest evidence_refs
    ].freeze

    attr_reader(*ATTRIBUTES)

    def self.from_hash(value)
      new(value.to_h.stringify_keys)
    end

    def initialize(value)
      @detected_language = value["detected_language"].to_s.strip
      @guest_question_es = value["guest_question_es"].to_s.strip
      @answer_summary_es = value["answer_summary_es"].to_s.strip
      @guest_reply = value["guest_reply"].to_s.strip.presence
      @confidence = Integer(value["confidence"], exception: false)
      @missing_information = ActiveModel::Type::Boolean.new.cast(value["missing_information"])
      @clarifying_question_es = value["clarifying_question_es"].to_s.strip.presence
      @clarifying_question_guest = value["clarifying_question_guest"].to_s.strip.presence
      @evidence_refs = Array(value["evidence_refs"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      validate!
    end

    def to_h
      ATTRIBUTES.index_with { |attribute| public_send(attribute) }
    end

    private

    def validate!
      required = {
        detected_language: detected_language,
        guest_question_es: guest_question_es,
        answer_summary_es: answer_summary_es,
        confidence: confidence
      }
      missing = required.select { |_key, value| value.blank? }.keys
      raise InvalidResponse, "missing fields: #{missing.join(', ')}" if missing.any?
      raise InvalidResponse, "confidence must be between 0 and 100" unless confidence.between?(0, 100)
      raise InvalidResponse, "clarifying_question_es is required" if missing_information && clarifying_question_es.blank?
      raise InvalidResponse, "guest_reply is required" if !missing_information && guest_reply.blank?
    end
  end
end
