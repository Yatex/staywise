module AI
  class DecisionResult
    ATTRIBUTES = %i[
      outcome
      response_text
      safe_fallback_response
      language
      intent_summary
      detected_intents
      evidence_ids
      used_source_ids
      required_capabilities
      missing_information
      safety_flags
      confidence
      evidence
      escalation
      proposed_action
      rejection_reason
      audit
      should_reply
      escalation_required
      escalation_reason
      sensitive_info_used
      alert_type
      alert_title
      alert_description
      suggested_owner_action
      owner_task_kind
      action
      answer_confidence
      task_summary
      attachments
    ].freeze

    attr_reader(*ATTRIBUTES)

    def self.from_hash(hash)
      normalized = hash.to_h.transform_keys(&:to_s)
      action = normalized["action"].presence
      decision = normalized["decision"].presence || normalized["outcome"] || outcome_for_action(action)
      message_body = normalized["message"].presence || normalized["message_body"].presence || normalized["response_text"]
      safe_fallback_response = normalized["safe_fallback_response"].presence || normalized["safe_response"].presence
      used_source_ids = Array(normalized["used_source_ids"]).compact_blank
      evidence_ids = Array(normalized["evidence_ids"]).presence ||
        used_source_ids.presence ||
        Array(normalized["evidence"]).filter_map { |item| item.to_h["evidence_id"].presence || item.to_h["source_id"] }

      new(
        outcome: decision,
        response_text: message_body,
        safe_fallback_response: safe_fallback_response,
        language: normalized["language"],
        intent_summary: normalized["intent_summary"],
        detected_intents: normalized.fetch("detected_intents", []),
        evidence_ids: evidence_ids,
        used_source_ids: used_source_ids,
        required_capabilities: normalized.fetch("required_capabilities", []),
        missing_information: normalized.fetch("missing_information", []),
        safety_flags: normalized.fetch("safety_flags", []),
        confidence: normalized.fetch("confidence", normalized.fetch("answer_confidence", 0).to_f / 100).to_f,
        evidence: normalized.fetch("evidence", evidence_ids.map { |evidence_id| { "evidence_id" => evidence_id } }),
        escalation: normalized["escalation"],
        proposed_action: normalized["proposed_action"],
        rejection_reason: normalized["rejection_reason"],
        audit: normalized.fetch("audit", {}),
        should_reply: normalized["should_reply"],
        escalation_required: normalized["escalation_required"],
        escalation_reason: normalized["escalation_reason"],
        sensitive_info_used: normalized["sensitive_info_used"],
        alert_type: normalized["alert_type"],
        alert_title: normalized["alert_title"],
        alert_description: normalized["alert_description"],
        suggested_owner_action: normalized["suggested_owner_action"],
        owner_task_kind: normalized["owner_task_kind"],
        action: action || action_for_outcome(decision, normalized["owner_task_kind"]),
        answer_confidence: normalized.fetch("answer_confidence", normalized.fetch("confidence", 0).to_f * 100).to_f,
        task_summary: normalized["task_summary"],
        attachments: normalized.fetch("attachments", [])
      )
    end

    def self.outcome_for_action(action)
      { "reply" => "reply", "clarify" => "ask_clarifying_question", "create_owner_task" => "propose_action" }[action.to_s]
    end

    def self.action_for_outcome(outcome, owner_task_kind)
      return "create_owner_task" if owner_task_kind.present? || outcome.to_s.in?(%w[escalate propose_action])
      return "clarify" if outcome.to_s == "ask_clarifying_question"

      "reply"
    end

    def initialize(attributes)
      ATTRIBUTES.each do |attribute|
        instance_variable_set("@#{attribute}", attributes[attribute])
      end

      @outcome = normalized_outcome
      @evidence = Array(@evidence).map { |item| item.to_h.stringify_keys }
      @evidence_ids = Array(@evidence_ids.presence || @evidence.map { |item| item["evidence_id"].presence || item["source_id"] }).compact_blank
      @used_source_ids = Array(@used_source_ids.presence || @evidence_ids).compact_blank
      @detected_intents = Array(@detected_intents).map { |item| item.to_h.stringify_keys }
      @required_capabilities = Array(@required_capabilities)
      @missing_information = Array(@missing_information)
      @safety_flags = Array(@safety_flags)
      @escalation = @escalation.to_h.stringify_keys if @escalation.present?
      @proposed_action = @proposed_action.to_h.stringify_keys if @proposed_action.present?
      @audit = @audit.to_h.stringify_keys
      @attachments = Array(@attachments).map { |item| item.to_h.stringify_keys }
      @answer_confidence = @answer_confidence.to_f
      @sensitive_info_used = ActiveModel::Type::Boolean.new.cast(@sensitive_info_used)
    end

    def to_h
      ATTRIBUTES.index_with { |attribute| public_send(attribute) }.merge(
        decision: outcome,
        message_body: response_text,
        message: response_text
      )
    end

    def should_reply
      return @should_reply unless @should_reply.nil?

      response_text.present? && !outcome.in?(%w[no_reply])
    end

    def escalation_required
      return true if outcome.in?(%w[escalate propose_action])
      return @escalation_required unless @escalation_required.nil?

      escalation.present? ? escalation.fetch("required", false) : false
    end

    def alert_type
      @alert_type || inferred_alert_type
    end

    def alert_title
      @alert_title || default_alert_title
    end

    def alert_description
      @alert_description || escalation&.fetch("summary_for_host", nil) || escalation&.fetch("summary", nil) || proposed_action&.fetch("details", nil) || proposed_action&.fetch("payload", nil)&.to_json || response_text
    end

    def suggested_owner_action
      @suggested_owner_action || default_suggested_owner_action
    end

    private

    def normalized_outcome
      value = @outcome.to_s
      return "no_reply" if value == "ignore"
      return value if value.in?(%w[reply ask_clarifying_question escalate propose_action no_reply])

      @escalation_required ? "escalate" : "reply"
    end

    def inferred_alert_type
      case proposed_action&.fetch("type", nil)
      when "late_checkout_request", "request_late_checkout"
        "late_checkout_request"
      when "maintenance_request", "report_issue"
        "maintenance_issue"
      when "guest_request", "request_extra_item", "request_service", "request_extra_bed", "request_food_or_drink", "request_transport", "request_other"
        "owner_approval_required"
      when "early_checkin_request", "booking_change_request", "refund_request", "access_request", "request_early_checkin", "request_reservation_extension", "human_handoff"
        "owner_approval_required"
      else
        case escalation&.fetch("category", nil) || escalation&.fetch("reason_code", nil)
        when "emergency"
          "emergency"
        when "maintenance"
          "maintenance_issue"
        when "complaint"
          "complaint"
        when "booking_change", "refund", "access"
          "owner_approval_required"
        when "missing_sensitive_information"
          "missing_sensitive_information"
        else
          escalation_required ? "unknown_question" : nil
        end
      end
    end

    def default_alert_title
      {
        "emergency" => "Emergencia",
        "maintenance_issue" => "Problema de mantenimiento",
        "complaint" => "Queja",
        "late_checkout_request" => "Solicitud de late checkout",
        "owner_approval_required" => "Requiere aprobación del propietario",
        "missing_sensitive_information" => missing_sensitive_alert_title,
        "unknown_question" => "Pregunta sin configurar"
      }.fetch(alert_type.to_s, "El huésped necesita atención del propietario")
    end

    def default_suggested_owner_action
      return proposed_action["details"] if proposed_action&.fetch("details", nil).present?

      {
        "emergency" => "Contactá al huésped de inmediato y compartí instrucciones de emergencia.",
        "maintenance_issue" => "Evaluá la urgencia, contactá mantenimiento y actualizá al huésped.",
        "complaint" => "Revisá el problema, acusá recibo de la queja y definí los próximos pasos.",
        "late_checkout_request" => "Confirmá disponibilidad y si aplica un costo antes de aprobar.",
        "owner_approval_required" => "Revisá la solicitud antes de confirmar algo al huésped.",
        "missing_sensitive_information" => "Respondé con el dato correcto para guardarlo de forma segura y enviarlo al huésped.",
        "unknown_question" => "Agregá la respuesta a la guía o FAQ de la propiedad y respondé al huésped."
      }.fetch(alert_type.to_s, "Revisá y respondé desde la conversación.")
    end

    def missing_sensitive_alert_title
      labels = {
        "property.safe_code" => "Código de caja fuerte",
        "property.lockbox_code" => "Código de caja de llaves",
        "property.door_code" => "Código de puerta",
        "property.gate_code" => "Código de portón",
        "property.alarm_code" => "Código de alarma",
        "property.building_access_code" => "Código de acceso al edificio",
        "property.key_location" => "Ubicación de llaves",
        "property.device_password" => "Contraseña de dispositivo"
      }
      missing = missing_information.find { |item| labels.key?(item.to_s) }

      ["Falta información", labels.fetch(missing.to_s, nil)].compact.join(" · ").presence ||
        "Falta información sensible"
    end
  end
end
