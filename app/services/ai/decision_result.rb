module AI
  class DecisionResult
    ATTRIBUTES = %i[
      outcome
      response_text
      confidence
      evidence
      escalation
      proposed_action
      rejection_reason
      audit
      should_reply
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
        outcome: normalized["outcome"],
        response_text: normalized["response_text"],
        confidence: normalized.fetch("confidence", 0.0).to_f,
        evidence: normalized.fetch("evidence", []),
        escalation: normalized["escalation"],
        proposed_action: normalized["proposed_action"],
        rejection_reason: normalized["rejection_reason"],
        audit: normalized.fetch("audit", {}),
        should_reply: normalized["should_reply"],
        escalation_required: normalized["escalation_required"],
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

      @outcome = normalized_outcome
      @evidence = Array(@evidence).map { |item| item.to_h.stringify_keys }
      @escalation = @escalation.to_h.stringify_keys if @escalation.present?
      @proposed_action = @proposed_action.to_h.stringify_keys if @proposed_action.present?
      @audit = @audit.to_h.stringify_keys
    end

    def to_h
      ATTRIBUTES.index_with { |attribute| public_send(attribute) }
    end

    def should_reply
      return @should_reply unless @should_reply.nil?

      response_text.present? && !outcome.in?(%w[no_reply])
    end

    def escalation_required
      return @escalation_required unless @escalation_required.nil?

      escalation.present? ? escalation.fetch("required", false) : outcome.in?(%w[escalate propose_action])
    end

    def alert_type
      @alert_type || inferred_alert_type
    end

    def alert_title
      @alert_title || default_alert_title
    end

    def alert_description
      @alert_description || escalation&.fetch("summary", nil) || proposed_action&.fetch("details", nil) || response_text
    end

    def suggested_owner_action
      @suggested_owner_action || default_suggested_owner_action
    end

    private

    def normalized_outcome
      value = @outcome.to_s
      return value if value.in?(%w[reply ask_clarifying_question escalate propose_action no_reply])

      @escalation_required ? "escalate" : "reply"
    end

    def inferred_alert_type
      case proposed_action&.fetch("type", nil)
      when "late_checkout_request"
        "late_checkout_request"
      when "maintenance_request"
        "maintenance_issue"
      when "early_checkin_request", "booking_change_request", "refund_request", "access_request"
        "owner_approval_required"
      else
        case escalation&.fetch("category", nil)
        when "emergency"
          "emergency"
        when "maintenance"
          "maintenance_issue"
        when "complaint"
          "complaint"
        when "booking_change", "refund", "access"
          "owner_approval_required"
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
        "unknown_question" => "Agregá la respuesta a la guía o FAQ de la propiedad y respondé al huésped."
      }.fetch(alert_type.to_s, "Revisá y respondé desde la conversación.")
    end
  end
end
