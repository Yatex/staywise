module AI
  class DecisionValidator
    Result = Struct.new(:valid?, :reasons, keyword_init: true)

    FORBIDDEN_APPROVAL_PATTERNS = [
      /yes,?\s+you can/i,
      /you may/i,
      /approved/i,
      /confirmed/i,
      /sí,?\s+pod[eé]s/i,
      /puedes/i,
      /aprobado/i,
      /confirmado/i
    ].freeze

    def initialize(conversation:, decision:, source: "ai")
      @conversation = conversation
      @decision = decision
      @source = source
      @registry = SourceRegistry.new(conversation: conversation)
    end

    def call
      reasons = []
      reasons << "invalid_outcome" unless @decision.outcome.in?(%w[reply ask_clarifying_question escalate propose_action no_reply])
      reasons << "low_confidence" if @decision.outcome == "reply" && @decision.confidence < SafetyConfig.minimum_reply_confidence
      reasons.concat(evidence_reasons)
      reasons << "sensitive_action_auto_approval" if sensitive_action_auto_approval?
      reasons << "sensitive_access_without_authorization" if sensitive_access_without_authorization?

      Result.new(valid?: reasons.empty?, reasons: reasons)
    end

    private

    def evidence_reasons
      return [] unless SafetyConfig.evidence_required?
      return [] unless @decision.outcome == "reply"

      return ["missing_evidence"] if @decision.evidence.blank?

      @decision.evidence.filter_map do |item|
        "invalid_evidence:#{item.to_h["source_id"]}" unless @registry.valid_evidence?(item)
      end
    end

    def sensitive_action_auto_approval?
      action = @decision.proposed_action.to_h
      sensitive_type = action["type"].to_s.in?(%w[
        early_checkin_request
        late_checkout_request
        refund_request
        booking_change_request
        access_request
      ])
      return false unless sensitive_type
      return false if action["requires_approval"] && @decision.escalation_required

      @decision.response_text.to_s.match?(Regexp.union(FORBIDDEN_APPROVAL_PATTERNS))
    end

    def sensitive_access_without_authorization?
      sensitive_evidence = @decision.evidence.any? do |item|
        source_id = item.to_h["source_id"].to_s
        source_id.in?(%w[property_fact:wifi_name property_fact:wifi_password property_fact:access_instructions])
      end
      return false unless sensitive_evidence

      !ReservationAuthorization.new(guest: @conversation.guest, property: @conversation.property).sensitive_access_authorized?
    end
  end
end
