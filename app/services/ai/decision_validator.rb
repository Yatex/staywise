module AI
  class DecisionValidator
    Result = Struct.new(:valid?, :reasons, :warnings, :contract_failed?, :tool_mandatory_failed?, keyword_init: true)

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
      reasons << "response_contradicts_evidence" if response_contradicts_evidence?
      reasons << "internal_metadata_visible" if internal_metadata_visible?
      reasons << "sensitive_action_auto_approval" if sensitive_action_auto_approval?
      reasons << "sensitive_access_without_authorization" if sensitive_access_without_authorization?
      reasons << "sensitive_info_without_sensitive_tool" if sensitive_info_without_sensitive_tool?
      reasons << "sensitive_info_flag_without_sensitive_evidence" if sensitive_info_flag_without_sensitive_evidence?
      reasons << "host_notification_claim_without_escalation" if host_notification_claim_without_escalation?
      reasons << "unresolved_detected_intents" if unresolved_detected_intents?
      warnings = validation_warnings

      Result.new(
        valid?: reasons.empty?,
        reasons: reasons,
        warnings: warnings,
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
      return [] if conversational_only_decision?
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
      return [] if conversational_only_decision?

      evidence_refs = evidence_refs_for_decision
      return ["missing_evidence"] if evidence_refs.blank?

      evidence_refs.flat_map do |item|
        reasons = []
        source_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"]
        reasons << "invalid_evidence:#{source_id}" unless @registry.valid_evidence?(item)
        reasons
      end
    end

    def evidence_refs_for_decision
      @decision.evidence.presence ||
        @decision.used_source_ids.map { |source_id| { "id" => source_id } }.presence ||
        @decision.evidence_ids.map { |evidence_id| { "evidence_id" => evidence_id } }
    end

    def response_contradicts_evidence?
      return false unless @decision.outcome == "reply"
      return false if conversational_only_decision?

      evidence_refs_for_decision.any? do |item|
        evidence_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"]
        source = @registry.source_for_evidence_id(evidence_id)
        next false if source.blank?

        contradicts_source_value?(source)
      end
    end

    def contradicts_source_value?(source)
      field = source["field"].to_s
      value = source["value"].to_s
      response = @decision.response_text.to_s
      return false if value.blank? || response.blank?

      case field
      when "check_in_time", "check_out_time"
        response_times = normalized_times(response)
        expected_times = normalized_times(value)
        response_times.present? && expected_times.present? && (response_times & expected_times).blank?
      else
        false
      end
    end

    def normalized_times(text)
      text.to_s.scan(/\b\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)?\b/i).map do |raw|
        normalized = raw.downcase.delete(".").squish
        if normalized.match?(/\A(\d{1,2})(am|pm)\z/)
          normalized = "#{Regexp.last_match(1)} #{Regexp.last_match(2)}"
        end
        time_to_minutes(normalized)
      end.compact.uniq
    end

    def time_to_minutes(value)
      match = value.match(/\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/i)
      return unless match

      hour = match[1].to_i
      minute = match[2].to_i
      meridian = match[3]
      return if hour > 24 || minute > 59

      if meridian == "pm" && hour < 12
        hour += 12
      elsif meridian == "am" && hour == 12
        hour = 0
      end

      (hour * 60) + minute
    end

    def internal_metadata_visible?
      text = @decision.response_text.to_s
      return false if text.blank?

      text.match?(
        /
          \(?\s*(source|source_id|evidence|evidence_id|used_source_ids?|matched_sources?|tool|tools|audit|trace)\s*[:：]|
          \b(property|reservation|guest|account|policy|faq|guide|recommendation|knowledge_block)\.[a-z0-9_.-]+\b|
          \b(property_fact|reservation_fact|knowledge_block|guest_context|property_brain|stay_facts):[a-z0-9_.:-]+\b
        /ix
      )
    end

    def sensitive_action_auto_approval?
      action = @decision.proposed_action.to_h
      sensitive_type = action["type"].to_s.in?(%w[
        early_checkin_request
        late_checkout_request
        refund_request
        booking_change_request
        access_request
      ]) || sensitive_request_message?
      return false unless sensitive_type
      return false if action["requires_approval"] && @decision.escalation_required

      @decision.response_text.to_s.match?(Regexp.union(FORBIDDEN_APPROVAL_PATTERNS))
    end

    def sensitive_request_message?
      @guest_message&.body.to_s.match?(
        /(entrar antes|early\s*check.?in|late\s*check.?out|salir mas tarde|salir más tarde|reembolso|refund|descuento|discount|extender|extension|extensión|cambiar reserva|booking change)/i
      )
    end

    def host_notification_claim_without_escalation?
      return false if @decision.escalation_required

      action_claim_about_host?
    end

    def escalate_without_required_flag?
      return false unless @decision.outcome == "escalate"

      !truthy?(@decision.escalation.to_h["required"])
    end

    def reply_claims_host_consult_without_alert_or_action?
      return false unless @decision.outcome == "reply"
      return false unless action_claim_about_host?

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
      return false unless action_claim_about_host?
      return false if @decision.outcome.in?(%w[escalate propose_action])
      return false if valid_proposed_action?

      true
    end

    def action_claim_about_host?
      text = normalized_response_text
      return false if text.blank?
      return false if conditional_host_offer?(text)
      return false if host_approval_requirement?(text)

      host_action_in_progress?(text) || host_action_completed?(text) || host_future_commitment?(text)
    end

    def normalized_response_text
      ActiveSupport::Inflector.transliterate(@decision.response_text.to_s.downcase).squish
    end

    def conditional_host_offer?(text)
      text.match?(
        /
          \?|
          \b(?:queres|quieres|necesitas|te gustaria|puedo|podemos|si necesitas|si queres|si quieres)\b.{0,90}\b(?:consult|confirm|verific|revis|pregunt|avis).{0,80}\b(?:host|anfitrion|dueno|duena|owner|propietario|propietaria)\b|
          \b(?:do you want|would you like|need me|i can|we can|if you need|if you want)\b.{0,90}\b(?:check|ask|confirm|verify).{0,80}\b(?:host|owner)\b
        /ix
      )
    end

    def host_approval_requirement?(text)
      text.match?(
        /
          \b(?:requiere|necesita|depende de|tendria que|debe|hay que)\b.{0,90}\b(?:confirm|aproba|autoriz|consult).{0,80}\b(?:host|anfitrion|dueno|duena|owner|propietario|propietaria)\b|
          \b(?:requires|needs|depends on|would need)\b.{0,90}\b(?:host|owner)\b.{0,80}\b(?:approval|confirmation|authorization)\b
        /ix
      )
    end

    def host_action_in_progress?(text)
      text.match?(
        /
          \b(?:estoy|estamos|i am|i'm|we are|we're)\b.{0,70}\b(?:consult\w*|confirm\w*|verific\w*|revis\w*|pregunt\w*|checking|asking|confirming|verifying)\b.{0,80}\b(?:host|anfitrion|dueno|duena|owner|propietario|propietaria)\b|
          \b(?:lo|la|esto|this|it)\b.{0,40}\b(?:estoy|estamos|i am|i'm|we are|we're)\b.{0,70}\b(?:consult\w*|confirm\w*|verific\w*|revis\w*|pregunt\w*|checking|asking|confirming|verifying)\b
        /ix
      )
    end

    def host_action_completed?(text)
      text.match?(
        /
          \b(?:ya|already)\b.{0,70}\b(?:consulte|consultamos|avise|avisamos|envie|enviamos|notifi|notificamos|mande|mandamos|sent|forwarded|notified|asked)\b.{0,90}\b(?:host|anfitrion|dueno|duena|owner|propietario|propietaria)?\b|
          \b(?:le|les)\b.{0,20}\b(?:avise|avisamos|envie|enviamos|notifi|notificamos|mande|mandamos)\b.{0,80}\b(?:host|anfitrion|dueno|duena|owner|propietario|propietaria)\b
        /ix
      )
    end

    def host_future_commitment?(text)
      text.match?(
        /
          \b(?:voy|vamos|i will|we will|i'll|we'll)\b.{0,70}\b(?:consult\w*|confirm\w*|verific\w*|revis\w*|pregunt\w*|avis\w*|notify|send|ask|check)\b.{0,90}\b(?:host|anfitrion|dueno|duena|owner|propietario|propietaria)?\b|
          \b(?:te|you)\b.{0,30}\b(?:aviso|avisare|responderemos|respondere|let you know|get back)\b
        /ix
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
        guest_request
        request_extra_item
        request_service
        request_extra_bed
        request_food_or_drink
        request_transport
        request_other
      ])
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def unresolved_detected_intents?
      return false if @decision.detected_intents.blank?

      @decision.outcome == "reply" && @decision.detected_intents.any? do |intent|
        intent["status"].blank? || !intent["status"].in?(%w[answered answered_with_inference needs_clarification requires_host_approval escalated])
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

    def conversational_only_decision?
      @decision.outcome == "reply" &&
        @decision.evidence_ids.blank? &&
        @decision.used_source_ids.blank? &&
        @decision.detected_intents.any? do |intent|
          intent.to_h["type"].to_s.in?(%w[routing_init greeting small_talk conversational_closure acknowledgement thanks goodbye])
        end
    end

    def validation_warnings
      semantic_relevance_warnings
    end

    def semantic_relevance_warnings
      return [] unless @decision.outcome == "reply"
      return [] if conversational_only_decision?
      return [] if grounded_decision_audit.blank?

      evidence_refs_for_decision.filter_map do |item|
        next unless @registry.valid_evidence?(item)

        evidence_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"]
        next if ai_marked_evidence_relevant?(evidence_id)

        "semantic_relevance_unverified:#{evidence_id}"
      end
    end

    def ai_marked_evidence_relevant?(evidence_id)
      canonical_id = canonical_evidence_reference(evidence_id)
      return true if grounded_decision_sufficient_evidence_ids.include?(canonical_id)

      grounded_decision_candidates.any? do |candidate|
        candidate = candidate.to_h
        canonical_evidence_reference(candidate["evidence_id"] || candidate[:evidence_id]) == canonical_id &&
          (candidate["score"] || candidate[:score]).to_f.positive?
      end
    end

    def grounded_decision_audit
      @grounded_decision_audit ||= @decision.audit.to_h["grounded_decision_builder"] || @decision.audit.to_h[:grounded_decision_builder]
    end

    def grounded_decision_candidates
      audit = grounded_decision_audit.to_h
      Array(audit["ranked_candidates"] || audit[:ranked_candidates]) |
        Array(audit["evidence_candidates_ranked"] || audit[:evidence_candidates_ranked])
    end

    def grounded_decision_sufficient_evidence_ids
      audit = grounded_decision_audit.to_h
      Array(audit["sufficient_candidates"] || audit[:sufficient_candidates]).filter_map do |candidate|
        canonical_evidence_reference(candidate.to_h["evidence_id"] || candidate.to_h[:evidence_id])
      end
    end

    def canonical_evidence_reference(reference)
      value = reference.to_s
      return if value.blank?

      case value
      when /\Aproperty_fact:(.+)\z/
        "property.#{$1}"
      when /\Aproperty_(.+)\z/
        "property.#{$1}"
      when /\Areservation_fact:(.+)\z/
        "reservation.#{$1}"
      when /\Areservation_(.+)\z/
        "reservation.#{$1}"
      when /\Asensitive_(.+)\z/
        "property.#{$1}"
      when /\Afaq_(\d+)\z/
        "faq.#{$1}"
      when /\Aguide_(\d+)\z/
        "guide.#{$1}"
      when /\Arecommendation_(\d+)\z/
        "recommendation.#{$1}"
      when /\Apolicy_(.+)\z/
        "policy.#{$1}"
      else
        value.tr(":", ".")
      end
    end

  end
end
