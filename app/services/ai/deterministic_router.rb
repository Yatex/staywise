module AI
  class DeterministicRouter
    EMERGENCY_PHRASES = [
      "emergency", "fire", "smoke", "gas leak", "flood", "police", "ambulance", "medical emergency",
      "incendio", "humo", "fuga de gas", "inundación", "policía", "policia", "ambulancia", "emergencia médica", "emergencia medica"
    ].freeze
    CONVERSATIONAL_CLOSURES = [
      "ok",
      "okay",
      "dale",
      "gracias",
      "muchas gracias",
      "perfecto",
      "bien",
      "entendido",
      "listo",
      "genial",
      "excelente",
      "no gracias",
      "asi esta bien",
      "no gracias asi esta bien",
      "esta bien",
      "todo bien",
      "ok gracias",
      "dale gracias",
      "perfecto gracias",
      "listo gracias",
      "👍"
    ].freeze

    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
      @registry = SourceRegistry.new(conversation: conversation)
      @text = guest_message.body.to_s.downcase
      @normalized_text = normalize_text(guest_message.body)
      @guest_language = LanguageHelper.detect(guest_message.body, fallback: conversation.guest.language)
      conversation.guest.update_column(:language, @guest_language) if @guest_language.present? && conversation.guest.language != @guest_language
    end

    def call
      simple_acknowledgement_decision || intro_decision || human_handoff_decision || emergency_decision
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
      text = @guest_message.body.to_s.gsub(Whatsapp::InboundMessageParser::PUBLIC_TOKEN_PATTERN, "")
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

    def simple_acknowledgement_decision
      return unless conversational_closure?

      decision(
        outcome: "no_reply",
        response_text: nil,
        should_reply: false,
        confidence: 1.0,
        evidence: [],
        escalation: { "required" => false, "category" => nil, "urgency" => nil, "summary" => nil },
        alert_type: nil,
        alert_title: nil,
        alert_description: nil,
        suggested_owner_action: nil,
        audit: { "route" => "deterministic_conversational_closure" }
      )
    end

    def conversational_closure?
      CONVERSATIONAL_CLOSURES.include?(@normalized_text)
    end

    def human_handoff_decision
      return unless @text.match?(/hablar.*(persona|humano|anfitri[oó]n|dueñ[oa])|quiero.*(persona|humano|anfitri[oó]n|dueñ[oa])|talk.*(person|human|host|owner)|speak.*(person|human|host|owner)/)

      decision(
        outcome: "escalate",
        response_text: LanguageHelper.human_handoff_ack_for(@guest_message.body, fallback_language: @guest_language),
        should_reply: true,
        confidence: 1.0,
        evidence: [],
        escalation: escalation("unknown", "medium", "Guest explicitly asked to speak with a human."),
        alert_type: "owner_approval_required",
        alert_title: "El huésped pidió hablar con una persona",
        alert_description: @guest_message.body,
        suggested_owner_action: "Respondé desde la conversación para continuar sin compartir tu número.",
        audit: { "route" => "deterministic_human_handoff" }
      )
    end

    def decision(attributes)
      DecisionResult.from_hash(attributes)
    end

    def normalize_text(value)
      ActiveSupport::Inflector.transliterate(value.to_s)
        .downcase
        .gsub(/[[:punct:]¿?¡!]+/, " ")
        .squish
    end

    def evidence_for(source, claim)
      source.slice("source_type", "source_id").merge("claim" => claim)
    end

    def escalation(category, urgency, summary)
      { "required" => true, "category" => category, "urgency" => urgency, "summary" => summary }
    end
  end
end
