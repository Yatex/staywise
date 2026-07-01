module AI
  class DeterministicRouter
    EMERGENCY_PHRASES = [
      "emergency", "fire", "smoke", "gas leak", "flood", "police", "ambulance", "medical emergency",
      "incendio", "humo", "fuga de gas", "inundación", "policía", "policia", "ambulancia", "emergencia médica", "emergencia medica"
    ].freeze

    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
      @registry = SourceRegistry.new(conversation: conversation)
      @authorization = ReservationAuthorization.new(guest: conversation.guest, property: @property)
      @text = guest_message.body.to_s.downcase
      @guest_language = LanguageHelper.detect(guest_message.body, fallback: conversation.guest.language)
      conversation.guest.update_column(:language, @guest_language) if @guest_language.present? && conversation.guest.language != @guest_language
    end

    def call
      intro_decision || emergency_decision || ambiguous_time_decision || sensitive_request_decision || sensitive_fact_decision || exact_fact_decision || reusable_knowledge_decision
    end

    private

    def intro_decision
      return unless intro_message?

      decision(
        outcome: "ask_clarifying_question",
        response_text: LanguageHelper.intro_reply_for(@property, @guest_message.body, fallback_language: @guest_language),
        should_reply: true,
        confidence: 1.0,
        evidence: [],
        escalation: { "required" => false, "category" => nil, "urgency" => nil, "summary" => nil },
        alert_type: nil,
        alert_title: nil,
        alert_description: nil,
        suggested_owner_action: nil,
        audit: { "route" => "deterministic_intro" }
      )
    end

    def intro_message?
      text = @guest_message.body.to_s.gsub(/(?:Ayla|Staywise) property #\d+/i, "")
      [@property.display_name, @property.name].compact_blank.uniq.each do |name|
        text = text.gsub(name.to_s, "")
      end

      text = text
        .downcase
        .gsub(/[[:punct:]¿?¡!]+/, " ")
        .squish

      return true if text.blank?

      normalized = text.gsub(/\b(hola|hello|hi|hey|buenas|buenos dias|buenos días|buenas tardes|buenas noches|tengo|una|un|consulta|sobre|del|de|la|el|para|por|favor|gracias)\b/i, " ").squish
      normalized.blank?
    end

    def emergency_decision
      phrase = EMERGENCY_PHRASES.find { |candidate| @text.include?(candidate) }
      return unless phrase

      source = @registry.property_fact("emergency_information")
      message = source&.fetch("value", nil).presence || LanguageHelper.emergency_ack_for(@guest_message.body, fallback_language: @guest_language)
      decision(
        outcome: "escalate",
        response_text: message,
        confidence: 1.0,
        evidence: source ? [evidence_for(source, "Emergency instructions configured for this property.")] : [],
        escalation: escalation("emergency", "urgent", "Emergency phrase matched: #{phrase}"),
        alert_type: "emergency",
        alert_title: "Emergencia reportada por huésped",
        alert_description: @guest_message.body,
        suggested_owner_action: "Contactá al huésped de inmediato y verificá si necesita asistencia urgente.",
        audit: { "route" => "deterministic_emergency", "matched_phrase" => phrase }
      )
    end

    def ambiguous_time_decision
      return unless ambiguous_time_question?

      decision(
        outcome: "ask_clarifying_question",
        response_text: LanguageHelper.ambiguous_time_reply_for(@guest_message.body, fallback_language: @guest_language),
        should_reply: true,
        confidence: 1.0,
        evidence: [],
        escalation: { "required" => false, "category" => nil, "urgency" => nil, "summary" => nil },
        alert_type: nil,
        alert_title: nil,
        alert_description: nil,
        suggested_owner_action: nil,
        audit: { "route" => "deterministic_ambiguous_time" }
      )
    end

    def ambiguous_time_question?
      return false unless @text.match?(/hora|time|heure|uhrzeit|horário|horario|ora|几点|何時|몇\s*시/)
      return false if @text.match?(/check.?in|check.?out|checkout|entrada|ingreso|llegar|arrival|arrive|salida|salir|leave|departure/)

      @text.match?(/puedo ir|puedo llegar|puedo pasar|can i go|can i come|can i arrive|what time can i|a qu[eé] hora|qué hora|que hora/)
    end

    def exact_fact_decision
      fact =
        if @text.match?(/check.?in|entrada|ingreso|llegar|arrival|arrive/)
          ["check_in_time", "Check-in time"]
        elsif @text.match?(/check.?out|salida|salir|leave|departure/)
          ["check_out_time", "Check-out time"]
        elsif @text.match?(/address|direcci[oó]n|ubicaci[oó]n/)
          ["address", "Property address"]
        elsif @text.match?(/parking|garage|estacionamiento|cochera/)
          ["parking", "Parking information"]
        elsif @text.match?(/house rules|rules|reglas|normas/)
          ["rules", "House rules"]
        end
      return unless fact

      source = @registry.property_fact(fact.first)
      return unknown_escalation("The guest asked for #{fact.last}, but that fact is not configured.") unless source

      decision(
        outcome: "reply",
        response_text: LanguageHelper.fact_reply_for(fact.first, source["value"], @guest_message.body, fallback_language: @guest_language),
        confidence: 1.0,
        evidence: [evidence_for(source, fact.last)],
        audit: { "route" => "deterministic_exact_fact", "field" => fact.first }
      )
    end

    def reusable_knowledge_decision
      if (faq = @registry.best_faq_for(@guest_message.body))
        source = @registry.faq_source(faq)
        return decision(
          outcome: "reply",
          response_text: faq.answer,
          confidence: 0.86,
          evidence: [evidence_for(source, "Best matching FAQ for the guest question.")],
          audit: { "route" => "deterministic_fuzzy_faq", "faq_id" => faq.id }
        )
      end

      if (block = @registry.best_knowledge_block_for(@guest_message.body))
        source = @registry.knowledge_source(block)
        response = [block.content, ("Video: #{block.youtube_url}" if block.youtube_url.present?)].compact.join("\n\n")
        return decision(
          outcome: "reply",
          response_text: response,
          confidence: 0.78,
          evidence: [evidence_for(source, "Best matching guide block for the guest question.")],
          audit: { "route" => "deterministic_fuzzy_knowledge_block", "knowledge_block_id" => block.id }
        )
      end
    end

    def sensitive_fact_decision
      field =
        if @text.match?(/wifi|wi-fi|password|contraseña|contrasena/)
          "wifi_password"
        elsif @text.match?(/door code|code|lock|access|entrada|acceso|cerradura|c[oó]digo/)
          "access_instructions"
        end
      return unless field

      unless @authorization.sensitive_access_authorized?
        return decision(
          outcome: "escalate",
          response_text: safe_ack,
          confidence: 1.0,
          evidence: [],
          escalation: escalation("access", "medium", "Guest requested sensitive #{field} without an authorized reservation window."),
          alert_type: "owner_approval_required",
          alert_title: "Solicitud de información sensible",
          alert_description: @guest_message.body,
          suggested_owner_action: "Verificá la reserva antes de compartir datos de acceso o WiFi.",
          audit: { "route" => "deterministic_sensitive_denied", "field" => field }
        )
      end

      sources = field == "wifi_password" ? [@registry.property_fact("wifi_name"), @registry.property_fact("wifi_password")].compact : [@registry.property_fact("access_instructions")].compact
      return unknown_escalation("The guest requested #{field}, but it is not configured.") if sources.blank?

      response =
        if field == "wifi_password"
          wifi_name = sources.find { |source| source["label"] == "wifi_name" }&.fetch("value", nil)
          wifi_password = sources.find { |source| source["label"] == "wifi_password" }&.fetch("value", nil)
          LanguageHelper.wifi_reply_for(name: wifi_name, password: wifi_password, text: @guest_message.body, fallback_language: @guest_language)
        else
          LanguageHelper.fact_reply_for(field, sources.first["value"], @guest_message.body, fallback_language: @guest_language)
        end
      decision(
        outcome: "reply",
        response_text: response,
        confidence: 1.0,
        evidence: sources.map { |source| evidence_for(source, "Authorized sensitive property fact.") },
        audit: { "route" => "deterministic_sensitive_allowed", "field" => field }
      )
    end

    def sensitive_request_decision
      type, category, summary =
        if @text.match?(/late checkout|salir.*tarde|checkout.*tarde/)
          ["late_checkout_request", "booking_change", "Late checkout request"]
        elsif @text.match?(/early check.?in|entrar.*antes|check.?in.*antes/)
          ["early_checkin_request", "booking_change", "Early check-in request"]
        elsif @text.match?(/refund|discount|compensation|reembolso|descuento|compensaci[oó]n/)
          ["refund_request", "refund", "Refund, discount, or compensation request"]
        elsif @text.match?(/change.*reservation|reservation change|cambiar.*reserva|cambio.*reserva/)
          ["booking_change_request", "booking_change", "Booking change request"]
        elsif @text.match?(/broken|leak|not working|damage|maintenance|roto|fuga|no funciona|daño|mantenimiento/)
          ["maintenance_request", "maintenance", "Maintenance issue"]
        elsif @text.match?(/complaint|dirty|bad|unhappy|queja|sucio|mal|decepcion/)
          [nil, "complaint", "Guest complaint"]
        end
      return unless category

      decision(
        outcome: type ? "propose_action" : "escalate",
        response_text: safe_ack,
        confidence: 1.0,
        evidence: [],
        escalation: escalation(category, category.in?(%w[maintenance complaint]) ? "high" : "medium", summary),
        proposed_action: type ? { "type" => type, "requires_approval" => true, "details" => @guest_message.body } : nil,
        alert_type: alert_type_for(type, category),
        alert_title: summary,
        alert_description: @guest_message.body,
        suggested_owner_action: "Revisá la solicitud y respondé antes de confirmar cualquier compromiso.",
        audit: { "route" => "deterministic_sensitive_request", "category" => category, "type" => type }
      )
    end

    def unknown_escalation(summary)
      decision(
        outcome: "escalate",
        response_text: safe_ack,
        confidence: 1.0,
        evidence: [],
        escalation: escalation("unknown", "medium", summary),
        alert_type: "unknown_question",
        alert_title: "Pregunta necesita respuesta del anfitrión",
        alert_description: @guest_message.body,
        suggested_owner_action: "Agregá esta información a las FAQs o guía si querés que la IA pueda responderla después.",
        audit: { "route" => "deterministic_missing_fact" }
      )
    end

    def decision(attributes)
      DecisionResult.from_hash(attributes)
    end

    def safe_ack
      LanguageHelper.safe_ack_for(@guest_message.body, fallback_language: @guest_language)
    end

    def evidence_for(source, claim)
      source.slice("source_type", "source_id").merge("claim" => claim)
    end

    def escalation(category, urgency, summary)
      { "required" => true, "category" => category, "urgency" => urgency, "summary" => summary }
    end

    def alert_type_for(type, category)
      return "late_checkout_request" if type == "late_checkout_request"
      return "maintenance_issue" if category == "maintenance"
      return "complaint" if category == "complaint"

      "owner_approval_required"
    end
  end
end
