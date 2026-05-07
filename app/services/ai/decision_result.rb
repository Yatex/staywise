module AI
  class DecisionResult
    ATTRIBUTES = %i[
      response_text
      should_reply
      confidence
      escalation_required
      alert_type
      alert_title
      alert_description
      suggested_owner_action
    ].freeze

    attr_reader(*ATTRIBUTES)

    def self.from_hash(hash)
      normalized = hash.to_h.transform_keys(&:to_s)
      new(
        response_text: normalized["response_text"],
        should_reply: normalized.fetch("should_reply", true),
        confidence: normalized.fetch("confidence", 0.0).to_f,
        escalation_required: normalized.fetch("escalation_required", false),
        alert_type: normalized["alert_type"],
        alert_title: normalized["alert_title"],
        alert_description: normalized["alert_description"],
        suggested_owner_action: normalized["suggested_owner_action"]
      )
    end

    def initialize(attributes)
      ATTRIBUTES.each do |attribute|
        instance_variable_set("@#{attribute}", attributes[attribute])
      end
    end

    def to_h
      ATTRIBUTES.index_with { |attribute| public_send(attribute) }
    end
  end
end
