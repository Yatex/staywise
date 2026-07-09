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
    CONVERSATIONAL_ONLY_TOKENS = %w[
      a ahi algo asi ate bem boa boas bom buen buena buenas bueno buenos bye chao chau coisa cualquier
      dale de dia dias entendido es esta excelente fine genial good goodbye gracias great hello hey hi hola
      afternoon evening is it later listo logo mais manana manha morning muchas muito need night no noite noches
      obrigada obrigado ok okay ola
      perfect perfecto perfeito see si sim tarde tardes thank thanks then todo tudo you welcome
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
      conversational_only_decision || intro_decision || human_handoff_decision || emergency_decision
    end

    private

    def conversational_only_decision
      return unless conversational_only?

      decision(
        outcome: "reply",
        response_text: LanguageHelper.conversational_reply_for(@guest_message.body, fallback_language: @guest_language),
        should_reply: true,
        confidence: 1.0,
        evidence: [],
        escalation: { "required" => false, "category" => nil, "urgency" => nil, "summary" => nil },
        alert_type: nil,
        alert_title: nil,
        alert_description: nil,
        suggested_owner_action: nil,
        audit: {
          "route" => "deterministic_conversational_only",
          "classification" => conversational_closure? ? "closure_or_acknowledgement" : "greeting_or_small_talk"
        }
      )
    end

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

    def conversational_closure?
      CONVERSATIONAL_CLOSURES.include?(@normalized_text)
    end

    def conversational_only?
      return true if conversational_closure?

      tokens = @normalized_text.split(/\s+/).compact_blank
      return false if tokens.blank?
      return false unless @normalized_text.match?(/\b(hola|buenas|buenos|buen|hello|hi|hey|good|ola|bom|boa|gracias|thanks|obrigado|obrigada|ok|okay|dale|perfecto|perfeito|bye|chau|chao)\b/)

      tokens.all? { |token| CONVERSATIONAL_ONLY_TOKENS.include?(token) }
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
