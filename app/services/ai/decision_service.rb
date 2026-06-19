require "net/http"
require "json"

module AI
  class DecisionService
    KEYWORD_ALERTS = {
      late_checkout_request: %w[late checkout stay longer leave later],
      missing_item: %w[towel towels linen sheets missing],
      maintenance_issue: %w[broken leak leaking damage not\ working],
      emergency: %w[emergency hospital police fire ambulance urgent],
      complaint: %w[complaint dirty bad unhappy disappointed],
      owner_approval_required: %w[refund discount compensation approve permission]
    }.freeze

    def self.call(conversation:, guest_message:)
      new(conversation: conversation, guest_message: guest_message).call
    end

    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
    end

    def call
      payload = ContextBuilder.new(conversation: @conversation, guest_message: @guest_message).call
      remote_decision(payload) || local_decision(payload)
    end

    private

    def remote_decision(payload)
      return if ENV["AI_SERVICE_URL"].blank?

      uri = URI.join(ENV.fetch("AI_SERVICE_URL"), "/decide")
      response = Net::HTTP.post(
        uri,
        payload.to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )

      return unless response.is_a?(Net::HTTPSuccess)

      DecisionResult.from_hash(JSON.parse(response.body))
    rescue StandardError => error
      Rails.logger.warn("[ai-decision] remote fallback: #{error.class}: #{error.message}")
      nil
    end

    def local_decision(payload)
      text = payload[:guest_message].to_s.downcase
      alert_type = detected_alert_type(text)

      return alert_decision(alert_type, payload[:guest_message]) if alert_type

      if recommendation_question?(text)
        recommendation_decision(payload)
      else
        knowledge_decision(payload, text)
      end
    end

    def detected_alert_type(text)
      KEYWORD_ALERTS.find do |_type, keywords|
        keywords.any? { |keyword| text.include?(keyword.tr("\\", "")) }
      end&.first
    end

    def alert_decision(alert_type, body)
      title = alert_title_for(alert_type)
      DecisionResult.from_hash(
        response_text: "Voy a consultarlo con tu anfitrión y te respondo en breve.",
        should_reply: true,
        confidence: 0.92,
        escalation_required: true,
        alert_type: alert_type,
        alert_title: title,
        alert_description: body,
        suggested_owner_action: suggested_action_for(alert_type)
      )
    end

    def recommendation_question?(text)
      text.match?(/eat|restaurant|cafe|coffee|supermarket|pharmacy|medicine|visit|attraction|transport|move around/)
    end

    def recommendation_decision(payload)
      recommendations = payload[:recommendations].first(3)

      if recommendations.any?
        lines = recommendations.map do |item|
          note = [item["description"], item["distance_or_walking_time"], item["owner_note"]].compact_blank.join(" ")
          "- #{item["name"]}: #{note.presence || item["category"].to_s.humanize}"
        end

        DecisionResult.from_hash(
          response_text: "Estas son algunas opciones recomendadas por el anfitrión:\n#{lines.join("\n")}",
          should_reply: true,
          confidence: 0.74,
          escalation_required: false
        )
      else
        unknown_decision("El huésped pidió una recomendación local, pero no hay ninguna configurada.")
      end
    end

    def knowledge_decision(payload, text)
      faq = payload[:faqs].find { |item| relevant?(text, item["question"]) }
      return answer_decision(faq["answer"], 0.83) if faq

      block = payload[:knowledge_blocks].find { |item| relevant?(text, [item["title"], item["category"], item["content"]].join(" ")) }
      return answer_decision(block["content"], 0.71) if block

      unknown_decision("La IA no encontró información cargada por el propietario para: #{payload[:guest_message]}")
    end

    def relevant?(message, source)
      words = message.scan(/[a-z0-9]+/).reject { |word| word.length < 4 }
      return false if words.blank?

      source_text = source.to_s.downcase
      words.any? { |word| source_text.include?(word) }
    end

    def answer_decision(answer, confidence)
      DecisionResult.from_hash(
        response_text: answer,
        should_reply: true,
        confidence: confidence,
        escalation_required: false
      )
    end

    def unknown_decision(description)
      DecisionResult.from_hash(
        response_text: "Todavía no tengo esa información. Voy a consultarlo con tu anfitrión y te respondo en breve.",
        should_reply: true,
        confidence: 0.28,
        escalation_required: true,
        alert_type: "unknown_question",
        alert_title: "La pregunta necesita respuesta del anfitrión",
        alert_description: description,
        suggested_owner_action: "Agregá la respuesta a la guía del huésped o a las FAQs de esta propiedad y luego respondé al huésped."
      )
    end

    def suggested_action_for(alert_type)
      {
        late_checkout_request: "Confirmá disponibilidad y si aplica un costo antes de aprobar.",
        missing_item: "Coordiná el reemplazo y avisale al huésped cuándo se resuelve.",
        maintenance_issue: "Evaluá la urgencia, contactá mantenimiento y actualizá al huésped.",
        emergency: "Contactá al huésped de inmediato y compartí instrucciones de emergencia.",
        complaint: "Revisá el problema, acusá recibo de la queja y definí los próximos pasos.",
        owner_approval_required: "Revisá la solicitud antes de que la IA o el propietario confirmen algo."
      }.fetch(alert_type, "Revisá y respondé desde la conversación.")
    end

    def alert_title_for(alert_type)
      {
        late_checkout_request: "Solicitud de late checkout",
        missing_item: "Objeto faltante",
        maintenance_issue: "Problema de mantenimiento",
        emergency: "Emergencia",
        complaint: "Queja",
        owner_approval_required: "Requiere aprobación del propietario",
        unknown_question: "Pregunta sin configurar"
      }.fetch(alert_type, alert_type.to_s.humanize)
    end
  end
end
