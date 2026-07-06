module AI
  class DecisionValidator
    Result = Struct.new(:valid?, :reasons, :contract_failed?, :tool_mandatory_failed?, keyword_init: true)

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
      reasons.concat(contract_reasons)
      reasons.concat(tool_mandatory_reasons)
      reasons << "missing_language" if @decision.language.blank?
      reasons << "low_confidence" if @decision.outcome == "reply" && @decision.confidence < SafetyConfig.minimum_reply_confidence
      reasons.concat(evidence_reasons)
      reasons << "sensitive_action_auto_approval" if sensitive_action_auto_approval?
      reasons << "sensitive_access_without_authorization" if sensitive_access_without_authorization?
      reasons << "sensitive_info_without_sensitive_tool" if sensitive_info_without_sensitive_tool?
      reasons << "sensitive_info_flag_without_sensitive_evidence" if sensitive_info_flag_without_sensitive_evidence?
      reasons << "approval_request_without_escalation" if approval_request_without_escalation?
      reasons << "host_notification_claim_without_escalation" if host_notification_claim_without_escalation?
      reasons << "unresolved_detected_intents" if unresolved_detected_intents?

      Result.new(
        valid?: reasons.empty?,
        reasons: reasons,
        contract_failed?: reasons.any? { |reason| reason.to_s.start_with?("contract_") },
        tool_mandatory_failed?: reasons.any? { |reason| reason.to_s.start_with?("tool_mandatory_failed") }
      )
    end

    private

    REAL_MESSAGE_EXCLUSION_PATTERN = /\A(?:hi|hello|hey|hola|buenas|buen dia|buenos dias|buenas tardes|buenas noches|gracias|muchas gracias|thanks|thank you|ok|okay|dale|listo|perfecto|entendido|genial|excelente|no gracias|asi esta bien|así está bien)\z/i
    HUMAN_OR_EMERGENCY_PATTERN = /(humano|persona|anfitri[oó]n|host|owner|emergency|emergencia|urgent|urgente|polic[ií]a|ambulancia|bomberos)/i

    REQUIRED_REAL_MESSAGE_TOOLS = %w[guest_context stay_facts].freeze

    TOOL_RELATED_QUERY_PATTERN = /
      check[\s-]?in|checkin|ingreso|entrada|arrival|arrive|arriv[eé]e|arrivée|
      check[\s-]?out|checkout|salida|departure|d[eé]part|départ|
      wifi|wi-fi|acceso|access|parking|estacionamiento|cochera|
      reglas|rules|horarios|hours|recomendaciones|recommendations
    /ix

    def contract_reasons
      reasons = []
      reasons << "contract_escalate_requires_escalation_required_true" if escalate_without_required_flag?
      reasons << "contract_reply_claims_host_consult_without_alert_or_action" if reply_claims_host_consult_without_alert_or_action?
      reasons << "contract_clarification_must_not_escalate_without_justification" if clarification_escalates_without_justification?
      reasons << "contract_no_reply_must_not_send_whatsapp" if no_reply_would_send_whatsapp?
      reasons << "contract_host_mention_requires_alert_or_valid_action" if host_mention_requires_alert_or_valid_action?
      reasons
    end

    def tool_mandatory_reasons
      return [] unless real_guest_message?

      reasons = []
      names = successful_tool_names
      if names.blank?
        reasons << "tool_mandatory_failed:real_guest_message_without_tools"
        reasons << "tool_mandatory_failed:unknown_intent_without_tools" if unknown_intent?
        reasons << "tool_mandatory_failed:escalation_without_tools" if @decision.outcome.in?(%w[escalate propose_action])
        return reasons
      end

      REQUIRED_REAL_MESSAGE_TOOLS.each do |tool_name|
        reasons << "tool_mandatory_failed:missing_#{tool_name}" unless names.include?(tool_name)
      end

      reasons << "tool_mandatory_failed:related_query_without_tools" if related_query? && names.blank?
      reasons
    end

    def real_guest_message?
      body = @guest_message&.body.to_s
      normalized = ActiveSupport::Inflector.transliterate(body.downcase).gsub(/[^\p{Alnum}\s-]+/, " ").squish
      return false if normalized.blank?
      return false if normalized.match?(REAL_MESSAGE_EXCLUSION_PATTERN)
      return false if body.match?(HUMAN_OR_EMERGENCY_PATTERN)

      true
    end

    def related_query?
      ActiveSupport::Inflector.transliterate(@guest_message&.body.to_s.downcase).match?(TOOL_RELATED_QUERY_PATTERN)
    end

    def unknown_intent?
      @decision.detected_intents.blank? ||
        @decision.detected_intents.any? { |intent| intent.to_h["type"].to_s == "unknown" }
    end

    def successful_tool_names
      tool_calls.filter_map do |tool|
        error = tool["error"] || tool[:error]
        next if error.present?

        tool["tool_name"] || tool["toolName"] || tool[:tool_name] || tool[:toolName]
      end.compact_blank.uniq
    end

    def tool_calls
      Array(@decision.audit.to_h["tool_calls"] || @decision.audit.to_h[:tool_calls])
    end

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

    def escalate_without_required_flag?
      return false unless @decision.outcome == "escalate"

      !truthy?(@decision.escalation.to_h["required"])
    end

    def reply_claims_host_consult_without_alert_or_action?
      return false unless @decision.outcome == "reply"
      return false unless host_consult_or_owner_mention?

      !valid_proposed_action?
    end

    def clarification_escalates_without_justification?
      return false unless @decision.outcome == "ask_clarifying_question"
      return false unless @decision.escalation_required || @decision.proposed_action.present?

      !explicit_escalation_justification?
    end

    def no_reply_would_send_whatsapp?
      return false unless @decision.outcome == "no_reply"

      @decision.should_reply || @decision.response_text.present?
    end

    def host_mention_requires_alert_or_valid_action?
      return false unless host_consult_or_owner_mention?
      return false if @decision.outcome.in?(%w[escalate propose_action])
      return false if valid_proposed_action?

      true
    end

    def host_consult_or_owner_mention?
      @decision.response_text.to_s.match?(
        /(host|anfitri[oó]n|dueñ[oa]|owner|propietari[oa]|consult|checking|check with|verific|revis|confirmar|confirmarlo|avis[eé]|notifi|envi[eé])/i
      )
    end

    def explicit_escalation_justification?
      escalation = @decision.escalation.to_h
      escalation["reason_code"].present? ||
        escalation["category"].present? ||
        escalation["summary_for_host"].present? ||
        escalation["summary"].present? ||
        valid_proposed_action?
    end

    def valid_proposed_action?
      action = @decision.proposed_action.to_h
      type = action["type"].to_s

      type.in?(%w[
        request_late_checkout
        late_checkout_request
        request_early_checkin
        early_checkin_request
        request_reservation_extension
        booking_change_request
        refund_request
        maintenance_request
        report_issue
        access_request
        human_handoff
      ])
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
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
