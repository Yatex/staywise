require "net/http"
require "json"

module AI
  class DecisionService
    def self.call(conversation:, guest_message:)
      new(conversation: conversation, guest_message: guest_message).call
    end

    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
      @guest_language = LanguageHelper.detect(guest_message.body, fallback: conversation.guest.language)
      @ai_request_payload = {}
      @ai_response_payload = {}
      @tool_calls = []
      conversation.guest.update_column(:language, @guest_language) if @guest_language.present? && conversation.guest.language != @guest_language
    end

    def call
      payload = ContextBuilder.new(conversation: @conversation, guest_message: @guest_message).call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if SafetyConfig.safe_router_enabled?
        routed = DeterministicRouter.new(conversation: @conversation, guest_message: @guest_message).call
        if routed
          audit("deterministic", routed, started_at, validation_results: { status: "skipped", reason: "deterministic_router" })
          return routed
        end
      end

      unless SafetyConfig.tool_first_flow_enabled?(account: @property.account, property: @property)
        fallback = safe_escalation("AI tool-first flow is disabled.")
        audit("tool_first_disabled", fallback, started_at, fallback_reason: "tool_first_disabled", validation_results: { status: "skipped" })
        return fallback
      end

      if (decision = remote_decision(payload))
        validation = DecisionValidator.new(conversation: @conversation, decision: decision, source: "ai").call
        if validation.valid?
          audit("remote_ai", decision, started_at, validator_result: "accepted", validation_results: validation_payload(validation, decision))
          return decision
        end

        Rails.logger.warn("[ai-audit] rejected decision=#{decision.to_h.except(:response_text).to_json} reasons=#{validation.reasons.join(",")}")
        fallback = safe_escalation("AI decision rejected: #{validation.reasons.join(", ")}")
        audit(
          "remote_ai_rejected",
          fallback,
          started_at,
          validator_result: "rejected",
          rejection_reason: validation.reasons.join(", "),
          rejected_decision: decision,
          fallback_reason: "validation_rejected",
          validation_results: validation_payload(validation, decision)
        )
        return fallback
      end

      fallback = safe_escalation("AI service unavailable.")
      audit("local_fallback", fallback, started_at, fallback_reason: @fallback_reason || "ai_service_unavailable", validation_results: { status: "skipped" })
      fallback
    end

    private

    def remote_decision(payload)
      return if ENV["AI_SERVICE_URL"].blank?

      @ai_request_payload = payload
      uri = URI.join(ENV.fetch("AI_SERVICE_URL"), "/decide")
      response = Net::HTTP.post(
        uri,
        payload.to_json,
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      )

      unless response.is_a?(Net::HTTPSuccess)
        @ai_response_payload = { status: response.code, body: parse_json_or_text(response.body) }
        @fallback_reason = "ai_service_status_#{response.code}"
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

      parsed = JSON.parse(response.body)
      @ai_response_payload = parsed
      @tool_calls = Array(parsed.dig("audit", "tool_calls"))
      DecisionResult.from_hash(parsed)
    rescue StandardError => error
      Rails.logger.warn("[ai-decision] remote fallback: #{error.class}: #{error.message}")
      @fallback_reason = "#{error.class}: #{error.message}"
      @ai_response_payload = { error_class: error.class.name, error_message: error.message }
      ErrorReporter.report(error, source: "ai_service", severity: "warning", account: @property.account, property: @property, context: ai_context)
      nil
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

    def audit(route, decision, started_at, validator_result: nil, rejection_reason: nil, rejected_decision: nil, validation_results: nil, fallback_reason: nil)
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      evidence_ids = decision.evidence_ids.presence || decision.evidence.map { |item| item["evidence_id"].presence || item["source_id"] }
      payload = {
        message_id: @guest_message.id,
        original_message_id: @guest_message.id,
        conversation_id: @conversation.id,
        guest_id: @conversation.guest_id,
        property_id: @property.id,
        route: route,
        outcome: decision.outcome,
        final_outcome: decision.outcome,
        alert_type: decision.alert_type,
        evidence_ids: evidence_ids,
        evidence_trace: evidence_trace(evidence_ids, validation_results),
        detected_intents: decision.detected_intents,
        missing_information: decision.missing_information,
        safety_flags: decision.safety_flags,
        validator_result: validator_result,
        validation_results: validation_results,
        rejection_reason: rejection_reason,
        fallback_reason: fallback_reason,
        replied_candidate: decision.should_reply,
        escalation_required: decision.escalation_required,
        latency_ms: latency_ms,
        model: ENV["AI_MODEL"],
        tool_calls: @tool_calls,
        checkin_trace: checkin_trace(decision, evidence_ids, validation_results, fallback_reason),
        rejected_candidate: rejected_decision_payload(rejected_decision)
      }.compact

      Rails.logger.info("[ai-audit] #{AIDecisionLog.sanitize_trace(payload).to_json}")
      persist_audit(payload, decision)
    end

    def persist_audit(payload, decision)
      AIDecisionLog.create!(
        account: @property.account,
        property: @property,
        guest: @conversation.guest,
        conversation: @conversation,
        message: @guest_message,
        original_message: @guest_message,
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
        ai_request_payload: AIDecisionLog.sanitize_trace(@ai_request_payload),
        ai_response_payload: AIDecisionLog.sanitize_trace(@ai_response_payload),
        tool_calls: AIDecisionLog.sanitize_trace(payload[:tool_calls] || []),
        validation_results: AIDecisionLog.sanitize_trace(payload[:validation_results] || {}),
        fallback_reason: payload[:fallback_reason],
        final_outcome: payload[:final_outcome],
        payload: AIDecisionLog.sanitize_trace(payload)
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

    def rejected_decision_payload(decision)
      return if decision.blank?

      decision.to_h.slice(
        :outcome,
        :response_text,
        :language,
        :detected_intents,
        :evidence_ids,
        :used_source_ids,
        :missing_information,
        :safety_flags,
        :confidence,
        :escalation_required,
        :alert_type,
        :proposed_action,
        :sensitive_info_used
      )
    end

    def validation_payload(validation, decision)
      {
        status: validation.valid? ? "accepted" : "rejected",
        passed: validation.valid?,
        failed: !validation.valid?,
        reasons: validation.reasons,
        evidence: evidence_validation(decision)
      }
    end

    def evidence_validation(decision)
      registry = SourceRegistry.new(conversation: @conversation, guest_message: @guest_message)
      refs = decision.evidence.presence ||
        decision.used_source_ids.map { |source_id| { "id" => source_id } }.presence ||
        decision.evidence_ids.map { |evidence_id| { "evidence_id" => evidence_id } }

      refs.map do |item|
        evidence_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"]
        source = registry.source_for_evidence_id(evidence_id)
        {
          evidence_id: evidence_id,
          valid: registry.valid_evidence?(item),
          relevant: registry.relevant_evidence?(item, @guest_message.body),
          source: source&.dig("source_type") || source&.dig("type"),
          field: source&.dig("field"),
          value: source&.dig("value")
        }
      end
    end

    def evidence_trace(evidence_ids, validation_results)
      validation_by_id = Array(validation_results.to_h[:evidence] || validation_results.to_h["evidence"]).index_by { |item| item[:evidence_id] || item["evidence_id"] }
      registry = SourceRegistry.new(conversation: @conversation, guest_message: @guest_message)

      Array(evidence_ids).compact_blank.map do |evidence_id|
        source = registry.source_for_evidence_id(evidence_id)
        validation = validation_by_id[evidence_id] || {}
        {
          evidence_id: evidence_id,
          source: source&.dig("source_type") || source&.dig("type"),
          field: source&.dig("field"),
          value: source&.dig("value"),
          valid: validation.fetch(:valid, validation.fetch("valid", nil)),
          relevant: validation.fetch(:relevant, validation.fetch("relevant", nil))
        }
      end
    end

    def checkin_trace(decision, evidence_ids, validation_results, fallback_reason)
      return unless @guest_message.body.to_s.match?(AIDecisionLog::CHECKIN_PATTERN)

      tool_names = @tool_calls.map { |tool| tool["tool_name"] || tool["toolName"] || tool[:tool_name] || tool[:toolName] }
      validation_passed = validation_results.to_h[:passed] || validation_results.to_h["passed"]
      check_in_evidence = Array(evidence_ids).find { |id| id.to_s.match?(/check_?in/i) }

      {
        label: "CHECKIN_TRACE",
        detected_language: decision.language || @guest_language,
        detected_intents: decision.detected_intents,
        guest_context_called: tool_names.include?("guest_context"),
        stay_facts_called: tool_names.include?("stay_facts") || tool_names.include?("property_brain"),
        check_in_evidence_found: check_in_evidence.present?,
        evidence_id: check_in_evidence,
        validation_passed: validation_passed,
        final_response_or_fallback: fallback_reason.presence || decision.response_text
      }
    end

    def parse_json_or_text(text)
      JSON.parse(text)
    rescue JSON::ParserError
      text.to_s.first(2_000)
    end
  end
end
