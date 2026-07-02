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
      @guest_language = LanguageHelper.detect(guest_message.body, fallback: conversation.guest.language)
      conversation.guest.update_column(:language, @guest_language) if @guest_language.present? && conversation.guest.language != @guest_language
    end

    def call
      payload = ContextBuilder.new(conversation: @conversation, guest_message: @guest_message).call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if SafetyConfig.safe_router_enabled?
        routed = DeterministicRouter.new(conversation: @conversation, guest_message: @guest_message).call
        if routed
          audit("deterministic", routed, started_at)
          return routed
        end
      end

      unless SafetyConfig.tool_first_flow_enabled?(account: @property.account, property: @property)
        fallback = local_decision(payload)
        audit("tool_first_disabled", fallback, started_at)
        return fallback
      end

      if (decision = remote_decision(payload))
        validation = DecisionValidator.new(conversation: @conversation, decision: decision, source: "ai").call
        if validation.valid?
          audit("remote_ai", decision, started_at, validator_result: "accepted")
          return decision
        end

        Rails.logger.warn("[ai-audit] rejected decision=#{decision.to_h.except(:response_text).to_json} reasons=#{validation.reasons.join(",")}")
        fallback = safe_escalation("AI decision rejected: #{validation.reasons.join(", ")}")
        audit("remote_ai_rejected", fallback, started_at, validator_result: "rejected", rejection_reason: validation.reasons.join(", "))
        return fallback
      end

      fallback = local_decision(payload)
      audit("local_fallback", fallback, started_at)
      fallback
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

      unless response.is_a?(Net::HTTPSuccess)
        fallback_decision = decision_from_error_response(response)
        ErrorReporter.report(
          source: "ai_service",
          severity: "warning",
          account: @property.account,
          property: @property,
          message: "AI service responded with status #{response.code}",
          context: ai_context.merge(status: response.code, response_body: response.body.to_s.first(1_000))
        )
        return fallback_decision
      end

      DecisionResult.from_hash(JSON.parse(response.body))
    rescue StandardError => error
      Rails.logger.warn("[ai-decision] remote fallback: #{error.class}: #{error.message}")
      ErrorReporter.report(error, source: "ai_service", severity: "warning", account: @property.account, property: @property, context: ai_context)
      nil
    end

    def local_decision(payload)
      return conservative_local_decision if SafetyConfig.conservative_fallback_enabled?

      legacy_local_decision(payload)
    end

    def conservative_local_decision
      registry = SourceRegistry.new(conversation: @conversation)
      faq = registry.exact_faq_for(@guest_message.body)

      if faq
        source = registry.faq_source(faq)
        return DecisionResult.from_hash(
          outcome: "reply",
          response_text: faq.answer,
          should_reply: true,
          confidence: 0.98,
          evidence: [source.slice("source_type", "source_id").merge("claim" => "Exact FAQ question match.")]
        )
      end

      safe_escalation("AI service unavailable and no exact FAQ match was found.")
    end

    def safe_escalation(description)
      DecisionResult.from_hash(
        decision: "escalate",
        language: @guest_language,
        message_body: guest_safe_ack,
        intent_summary: description,
        detected_intents: [{ type: "unknown", status: "escalated" }],
        evidence_ids: [],
        required_capabilities: [],
        missing_information: [@guest_message.body],
        safety_flags: ["fallback"],
        should_reply: true,
        confidence: 1.0,
        evidence: [],
        escalation: {
          required: true,
          category: "unknown",
          urgency: "medium",
          reason_code: "unknown_question",
          summary: description,
          summary_for_host: description
        },
        proposed_action: nil,
        alert_type: "unknown_question",
        alert_title: "La pregunta necesita respuesta del anfitrión",
        alert_description: @guest_message.body,
        suggested_owner_action: "Revisá la consulta antes de responder. Si es información reusable, agregala como FAQ o bloque de guía."
      )
    end

    def legacy_local_decision(payload)
      text = payload[:guest_message].to_s.downcase
      alert_type = detected_alert_type(text)

      return alert_decision(alert_type, payload[:guest_message]) if alert_type

      safe_escalation("AI service unavailable.")
    end

    def detected_alert_type(text)
      KEYWORD_ALERTS.find do |_type, keywords|
        keywords.any? { |keyword| text.include?(keyword.tr("\\", "")) }
      end&.first
    end

    def alert_decision(alert_type, body)
      title = alert_title_for(alert_type)
      DecisionResult.from_hash(
        response_text: guest_safe_ack(body),
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
      return answer_decision(block["content"], 0.71, video_url: block["youtube_url"]) if block

      unknown_decision(payload[:guest_message])
    end

    def relevant?(message, source)
      words = message.scan(/[a-z0-9]+/).reject { |word| word.length < 4 }
      return false if words.blank?

      source_text = source.to_s.downcase
      words.any? { |word| source_text.include?(word) }
    end

    def answer_decision(answer, confidence, video_url: nil)
      response_text = [answer, ("Video: #{video_url}" if video_url.present?)].compact.join("\n\n")

      DecisionResult.from_hash(
        response_text: response_text,
        should_reply: true,
        confidence: confidence,
        escalation_required: false
      )
    end

    def unknown_decision(description)
      DecisionResult.from_hash(
        response_text: guest_safe_ack(description),
        should_reply: true,
        confidence: 0.28,
        escalation_required: true,
        alert_type: "unknown_question",
        alert_title: "La pregunta necesita respuesta del anfitrión",
        alert_description: description,
        suggested_owner_action: "Agregá la respuesta a la guía del huésped o a las FAQs de esta propiedad y luego respondé al huésped."
      )
    end

    def audit(route, decision, started_at, validator_result: nil, rejection_reason: nil)
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      payload = {
        message_id: @guest_message.id,
        conversation_id: @conversation.id,
        guest_id: @conversation.guest_id,
        property_id: @property.id,
        route: route,
        outcome: decision.outcome,
        alert_type: decision.alert_type,
        evidence_ids: decision.evidence_ids.presence || decision.evidence.map { |item| item["evidence_id"].presence || item["source_id"] },
        detected_intents: decision.detected_intents,
        missing_information: decision.missing_information,
        safety_flags: decision.safety_flags,
        validator_result: validator_result,
        rejection_reason: rejection_reason,
        replied_candidate: decision.should_reply,
        escalation_required: decision.escalation_required,
        latency_ms: latency_ms,
        model: ENV["AI_MODEL"]
      }.compact

      Rails.logger.info("[ai-audit] #{payload.to_json}")
      persist_audit(payload, decision)
    end

    def persist_audit(payload, decision)
      AiDecisionLog.create!(
        account: @property.account,
        property: @property,
        guest: @conversation.guest,
        conversation: @conversation,
        message: @guest_message,
        route: payload.fetch(:route),
        decision: decision.outcome,
        language: decision.language || @guest_language,
        validator_result: payload[:validator_result],
        rejection_reason: payload[:rejection_reason],
        escalation_required: decision.escalation_required,
        replied_candidate: decision.should_reply,
        latency_ms: payload[:latency_ms],
        model: payload[:model],
        detected_intents: decision.detected_intents,
        evidence_ids: payload[:evidence_ids],
        missing_information: decision.missing_information,
        safety_flags: decision.safety_flags,
        payload: payload
      )
    rescue StandardError => error
      Rails.logger.warn("[ai-audit] persist_failed #{error.class}: #{error.message}")
    end

    def guest_safe_ack(text = @guest_message.body)
      LanguageHelper.safe_ack_for(text, fallback_language: @guest_language)
    end

    def ai_context
      {
        ai_service_url: ENV["AI_SERVICE_URL"],
        conversation_id: @conversation.id,
        guest_id: @conversation.guest_id,
        message_id: @guest_message.id
      }.compact
    end

    def decision_from_error_response(response)
      parsed = JSON.parse(response.body)
      return unless parsed.is_a?(Hash) && parsed["outcome"].present?

      DecisionResult.from_hash(parsed)
    rescue JSON::ParserError
      nil
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
