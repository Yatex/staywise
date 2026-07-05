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
      @guest_message = conversation.messages.where(sender: "guest").order(created_at: :desc).first
    end

    def call
      reasons = []
      reasons << "invalid_outcome" unless @decision.outcome.in?(%w[reply ask_clarifying_question escalate propose_action no_reply])
      reasons << "wrong_language" if wrong_language?
      reasons << "low_confidence" if @decision.outcome == "reply" && @decision.confidence < SafetyConfig.minimum_reply_confidence
      reasons.concat(evidence_reasons)
      reasons << "sensitive_action_auto_approval" if sensitive_action_auto_approval?
      reasons << "sensitive_access_without_authorization" if sensitive_access_without_authorization?
      reasons << "sensitive_info_without_sensitive_tool" if sensitive_info_without_sensitive_tool?
      reasons << "sensitive_info_flag_without_sensitive_evidence" if sensitive_info_flag_without_sensitive_evidence?
      reasons << "approval_request_without_escalation" if approval_request_without_escalation?
      reasons << "host_notification_claim_without_escalation" if host_notification_claim_without_escalation?
      reasons << "unresolved_detected_intents" if unresolved_detected_intents?

      Result.new(valid?: reasons.empty?, reasons: reasons)
    end

    private

    def evidence_reasons
      return [] unless SafetyConfig.evidence_required?
      return [] unless @decision.outcome == "reply"

      evidence_refs = evidence_refs_for_decision
      return ["missing_evidence"] if evidence_refs.blank?

      evidence_refs.flat_map do |item|
        reasons = []
        source_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"]
        reasons << "invalid_evidence:#{source_id}" unless @registry.valid_evidence?(item)
        reasons << "irrelevant_evidence:#{source_id}" unless @registry.relevant_evidence?(item, @guest_message&.body)
        reasons
      end
    end

    def evidence_refs_for_decision
      @decision.evidence.presence ||
        @decision.used_source_ids.map { |source_id| { "id" => source_id } }.presence ||
        @decision.evidence_ids.map { |evidence_id| { "evidence_id" => evidence_id } }
    end

    def wrong_language?
      expected = LanguageHelper.detect(@guest_message&.body, fallback: @conversation.guest.language)
      return false if expected.blank? || @decision.language.blank?

      @decision.language.to_s.split(/[-_]/).first != expected
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

    def host_notification_claim_without_escalation?
      return false if @decision.escalation_required

      @decision.response_text.to_s.match?(/(ya|already).*(avis[eé]|envi[eé]|notifi|sent|forwarded).*(host|anfitri[oó]n|dueñ[oa]|owner)/i)
    end

    def unresolved_detected_intents?
      return false if @decision.detected_intents.blank?

      @decision.outcome == "reply" && @decision.detected_intents.any? do |intent|
        intent["status"].blank? || !intent["status"].in?(%w[answered needs_clarification requires_host_approval escalated])
      end
    end

    def sensitive_access_without_authorization?
      return false unless @decision.sensitive_info_used || sensitive_evidence?

      !ReservationAuthorization.new(guest: @conversation.guest, property: @conversation.property).sensitive_access_authorized?
    end

    def sensitive_info_without_sensitive_tool?
      return false unless sensitive_response?
      return false if @decision.sensitive_info_used

      true
    end

    def sensitive_info_flag_without_sensitive_evidence?
      return false unless @decision.sensitive_info_used

      !sensitive_evidence?
    end

    def sensitive_evidence?
      evidence_refs_for_decision.any? do |item|
        evidence_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"].to_s
        evidence_id.in?(%w[
          property_fact:wifi_name
          property_fact:wifi_password
          property_fact:access_instructions
          property.wifi_name
          property.wifi_password
          property.access_instructions
          sensitive_wifi_name
          sensitive_wifi_password
          sensitive_access_instructions
        ])
      end
    end

    def sensitive_response?
      @decision.response_text.to_s.match?(
        /(?:wifi|wi-fi).{0,50}(?:password|contrase(?:ñ|n)a|clave|red|network|is|es)|(?:password|contrase(?:ñ|n)a|clave).{0,50}(?:wifi|wi-fi|is|es)|(?:c[oó]digo|code|lockbox|caja de llaves|cerradura|llave|keys?|access code|instrucciones de acceso)/i
      )
    end

    def approval_request_without_escalation?
      return false unless @decision.outcome == "reply"
      return false unless approval_or_exception_request?

      true
    end

    def approval_or_exception_request?
      text = @guest_message&.body.to_s.downcase
      normalized = ActiveSupport::Inflector.transliterate(text)

      normalized.match?(
        /(?:puedo|podria|podrias|me dejan|me dejarian|quiero|necesito|can i|could i|may i).*(?:late checkout|checkout.*tarde|salir.*tarde|check.?in.*antes|entrar.*antes|extender|extension|alargar|refund|reembolso|descuento|discount|compensation|compensacion)/
      ) ||
        normalized.match?(/(?:extender|alargar).*(?:reserva|reservation)/) ||
        normalized.match?(/(?:hacer|salir).*(?:mas tarde|tarde).*(?:checkout|check out|salida)/)
    end
  end
end
