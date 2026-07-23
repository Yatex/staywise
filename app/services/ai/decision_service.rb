require "net/http"
require "json"

module AI
  class DecisionService
    RETRYABLE_TRANSPORT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, EOFError, Errno::ECONNRESET].freeze
    MAX_REMOTE_ATTEMPTS = 2
    RETRY_DELAY_SECONDS = 2

    def self.call(conversation:, guest_message:)
      new(conversation: conversation, guest_message: guest_message).call
    end

    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
      @fallback_language = LanguageHelper.normalize_code(conversation.guest.language).presence || LanguageHelper.owner_language(@property.account)
      @ai_request_payload = {}
      @ai_response_payload = {}
      @tool_calls = []
    end

    def call
      payload = ContextBuilder.new(conversation: @conversation, guest_message: @guest_message).call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @call_started_at = started_at
      log_ai_payload_size(payload)

      unless SafetyConfig.tool_first_flow_enabled?(account: @property.account, property: @property)
        fallback = safe_no_reply("AI tool-first flow is disabled.", flag: "tool_first_disabled")
        audit("tool_first_disabled", fallback, started_at, fallback_reason: "tool_first_disabled", validation_results: { status: "skipped" })
        return fallback
      end

      if (decision = remote_decision(payload))
        validation = DecisionValidator.new(conversation: @conversation, decision: decision, source: "ai").call
        if validation.valid?
          accepted_with_warnings = validation.warnings.present?
          audit(
            accepted_with_warnings ? "remote_ai_accepted_with_warnings" : "remote_ai",
            decision,
            started_at,
            validator_result: accepted_with_warnings ? "accepted_with_warnings" : "accepted",
            validation_results: validation_payload(validation, decision)
          )
          return decision
        end

        Rails.logger.warn("[ai-audit] rejected decision=#{decision.to_h.except(:response_text).to_json} reasons=#{validation.reasons.join(",")}")
        report_evidence_provenance_failure(decision, validation) if validation.reasons.any? { |reason| reason.start_with?("evidence_provenance_violation:") }
        if validation.contract_failed?
          report_contract_validation_failure(decision, validation)
          fallback = technical_fallback("AI contract validation failed: #{validation.reasons.join(", ")}")
          audit(
            "remote_ai_contract_rejected",
            fallback,
            started_at,
            validator_result: "contract_validation_failed",
            rejection_reason: validation.reasons.join(", "),
            rejected_decision: decision,
            fallback_reason: "contract_validation_failed",
            rails_fallback_source: "rails_technical_fallback",
            validation_results: validation_payload(validation, decision)
          )
          return fallback
        end

        fallback = technical_fallback("AI decision rejected: #{validation.reasons.join(", ")}")
        audit(
          "remote_ai_rejected",
          fallback,
          started_at,
          validator_result: "rejected",
          rejection_reason: validation.reasons.join(", "),
          rejected_decision: decision,
          fallback_reason: "validation_rejected",
          rails_fallback_source: "rails_technical_fallback",
          validation_results: validation_payload(validation, decision)
        )
        return fallback
      end

      fallback = technical_fallback("AI service unavailable.", error: @fallback_error)
      audit("local_fallback", fallback, started_at, fallback_reason: @fallback_reason || "ai_service_unavailable", validation_results: { status: "skipped" })
      fallback
    end

    private

    def remote_decision(payload)
      return if ENV["AI_SERVICE_URL"].blank?

      @ai_request_payload = payload
      uri = URI.join(ENV.fetch("AI_SERVICE_URL"), "/decide")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{ENV.fetch("AI_SERVICE_TOKEN", "")}"
      request["X-Request-ID"] = payload[:correlation_id].to_s if payload[:correlation_id].present?
      request.body = payload.to_json
      response = request_with_timeout_retry(uri, request)

      unless response.is_a?(Net::HTTPSuccess)
        @ai_response_payload = { status: response.code, body: parse_json_or_text(response.body) }
        parsed_error_payload = @ai_response_payload[:body]
        @ai_response_payload = parsed_error_payload.merge("status" => response.code) if parsed_error_payload.is_a?(Hash)
        @tool_calls = Array(@ai_response_payload.to_h.dig("audit", "tool_calls"))
        @fallback_http_status = response.code.to_i
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
      @fallback_error = error
      @fallback_reason = "#{error.class}: #{error.message}"
      @ai_response_payload = { error_class: error.class.name, error_message: error.message }
      ErrorReporter.report(error, source: "ai_service", severity: "warning", account: @property.account, property: @property, context: ai_context)
      nil
    end

    def request_with_timeout_retry(uri, request)
      attempts = 0

      begin
        attempts += 1
        @ai_service_attempts = attempts
        request["X-Ayla-Attempt"] = attempts.to_s
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
          http.request(request)
        end
      rescue *RETRYABLE_TRANSPORT_ERRORS => error
        @ai_service_retry_errors ||= []
        @ai_service_retry_errors << { "attempt" => attempts, "error_class" => error.class.name }
        raise if attempts >= MAX_REMOTE_ATTEMPTS

        Rails.logger.warn(
          "[ai-decision] retrying remote request after #{error.class} " \
          "attempt=#{attempts} request_id=#{@ai_request_payload.to_h[:correlation_id] || @ai_request_payload.to_h['correlation_id']}"
        )
        pause_before_timeout_retry
        retry
      end
    end

    def pause_before_timeout_retry
      sleep(RETRY_DELAY_SECONDS)
    end

    def safe_no_reply(description, flag: "contract_validation_failed")
      DecisionResult.from_hash(
        decision: "no_reply",
        language: @fallback_language,
        message_body: nil,
        intent_summary: description,
        detected_intents: [{ type: flag, status: "blocked" }],
        evidence_ids: [],
        required_capabilities: [],
        missing_information: [],
        safety_flags: [flag],
        should_reply: false,
        confidence: 1.0,
        evidence: [],
        escalation: { required: false },
        proposed_action: nil
      )
    end

    def report_contract_validation_failure(decision, validation)
      ErrorReporter.report(
        source: "ai_contract",
        severity: "warning",
        account: @property.account,
        property: @property,
        message: "AI contract validation failed",
        context: ai_context.merge(
          decision: decision.outcome,
          alert_type: decision.alert_type,
          reasons: validation.reasons,
          rejected_decision: rejected_decision_payload(decision)
        )
      )
    end

    def report_evidence_provenance_failure(decision, validation)
      ErrorReporter.report(
        source: "ai_evidence_provenance",
        severity: "error",
        account: @property.account,
        property: @property,
        message: "AI evidence provenance validation failed",
        context: ai_context.merge(
          decision: decision.outcome,
          conversation_property_id: @property.id,
          conversation_account_id: @property.account_id,
          reasons: validation.reasons,
          evidence: evidence_validation(decision)
        )
      )
    end

    def technical_fallback(description, error: nil)
      @fallback_diagnostic = TechnicalFallback.new(
        property: @property,
        error: error,
        response_payload: @ai_response_payload,
        http_status: @fallback_http_status,
        duration_ms: current_duration_ms,
        correlation_id: @ai_request_payload.to_h[:correlation_id] || @ai_request_payload.to_h["correlation_id"],
        request_id: @ai_request_payload.to_h[:correlation_id] || @ai_request_payload.to_h["correlation_id"],
        provider: fallback_provider,
        tools: @tool_calls
      ).diagnostic

      DecisionResult.from_hash(
        action: "reply",
        message: @fallback_diagnostic.fetch(:message_sent),
        answer_confidence: 100,
        language: @fallback_language,
        intent_summary: description,
        detected_intents: [{ type: "technical_fallback", status: "blocked" }],
        evidence_ids: [],
        attachments: [],
        safety_flags: ["rails_technical_fallback"],
        should_reply: true,
        owner_task_kind: nil
      )
    end

    def audit(route, decision, started_at, validator_result: nil, rejection_reason: nil, rejected_decision: nil, validation_results: nil, fallback_reason: nil, rails_fallback_source: nil)
      persist_decision_language(decision)
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      original_decision = rejected_decision || decision
      evidence_ids = decision_evidence_ids(original_decision)
      @tool_calls = ToolTraceEnricher.new(
        conversation: @conversation,
        guest_message: @guest_message,
        tool_calls: @tool_calls,
        evidence_catalog: @ai_response_payload.to_h.deep_stringify_keys.dig("audit", "evidence_catalog"),
        referenced_evidence_ids: evidence_ids,
        validation_results: validation_results,
        decision_context_id: @ai_request_payload.to_h.dig(:tool_endpoint, :decision_context_id) ||
          @ai_request_payload.to_h.dig("tool_endpoint", "decision_context_id")
      ).call
      payload = {
        message_id: @guest_message.id,
        original_message_id: @guest_message.id,
        conversation_id: @conversation.id,
        guest_id: @conversation.guest_id,
        property_id: @property.id,
        conversation_property_id: @property.id,
        conversation_account_id: @property.account_id,
        route: route,
        original_decision: rejected_decision_payload(original_decision),
        outcome: decision.outcome,
        final_outcome: decision.outcome,
        final_response_text: decision.response_text,
        answer_confidence: decision.answer_confidence,
        attachments: decision.attachments,
        rails_fallback_source: rails_fallback_source,
        rails_used_technical_fallback: rails_fallback_source == "rails_technical_fallback",
        fallback_language: decision.language || @fallback_language,
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
        ai_service_attempts: @ai_service_attempts || 0,
        ai_service_retry_errors: @ai_service_retry_errors || [],
        model: ENV["AI_MODEL"],
        correlation_id: @ai_request_payload.to_h[:correlation_id] || @ai_request_payload.to_h["correlation_id"],
        tool_calls: @tool_calls,
        checkin_trace: checkin_trace(decision, evidence_ids, validation_results, fallback_reason),
        fallback_diagnostic: @fallback_diagnostic,
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
        language: decision.language || @fallback_language,
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
        ai_request_payload: AIDecisionLog.sanitize_trace(compact_trace_payload(@ai_request_payload)),
        ai_response_payload: AIDecisionLog.sanitize_trace(compact_trace_payload(@ai_response_payload)),
        tool_calls: AIDecisionLog.sanitize_trace(payload[:tool_calls] || []),
        validation_results: AIDecisionLog.sanitize_trace(payload[:validation_results] || {}),
        fallback_reason: payload[:fallback_reason],
        final_outcome: payload[:final_outcome],
        payload: AIDecisionLog.sanitize_trace(payload)
      )
    rescue StandardError => error
      Rails.logger.warn("[ai-audit] persist_failed #{error.class}: #{error.message}")
    end

    def log_ai_payload_size(payload)
      counts = {
        conversation_messages: Array(payload[:conversation_history]).size,
        active_faqs: @property.faqs.active.count,
        appliance_guides: @property.knowledge_blocks.active.where(category: "appliances").count,
        knowledge_blocks: @property.knowledge_blocks.active.count,
        recommendations: @property.recommendations.count
      }

      Rails.logger.info(
        "[ai-payload] " \
          "conversation_id=#{@conversation.id} " \
          "message_id=#{@guest_message.id} " \
          "bytes=#{payload.to_json.bytesize} " \
          "counts=#{counts.to_json}"
      )
    rescue StandardError => error
      Rails.logger.debug("[ai-payload] size_log_failed #{error.class}: #{error.message}")
    end

    def compact_trace_payload(value, depth = 0, parent_key = nil)
      return "[TRUNCATED_DEPTH]" if depth > 8

      case value
      when Hash
        value.to_h.each_with_object({}) do |(key, item), result|
          result[key.to_s] = compact_trace_payload(item, depth + 1, key.to_s)
        end
      when Array
        limit = trace_array_limit(parent_key)
        compacted = value.first(limit).map { |item| compact_trace_payload(item, depth + 1, parent_key) }
        return compacted if value.size <= limit

        compacted + [{ "_truncated" => true, "omitted_count" => value.size - limit }]
      when String
        limit = trace_string_limit(parent_key)
        value.length > limit ? "#{value.first(limit)}...[TRUNCATED #{value.length - limit} chars]" : value
      else
        value
      end
    end

    def trace_array_limit(key)
      case key.to_s
      when "conversation_history" then 12
      when "evidence_catalog" then 40
      when "tool_calls" then 20
      when "tool_results" then 20
      else 50
      end
    end

    def trace_string_limit(key)
      case key.to_s
      when "raw_text", "response_text", "message_body" then 6_000
      else 4_000
      end
    end

    def persist_decision_language(decision)
      language = LanguageHelper.normalize_code(decision.language).presence || @fallback_language
      return if language.blank? || @conversation.guest.language == language

      @conversation.guest.update_column(:language, language)
    end

    def ai_context
      {
        ai_service_url: ENV["AI_SERVICE_URL"],
        conversation_id: @conversation.id,
        guest_id: @conversation.guest_id,
        message_id: @guest_message.id,
        request_id: @ai_request_payload.to_h[:correlation_id] || @ai_request_payload.to_h["correlation_id"],
        ai_service_attempts: @ai_service_attempts
      }.compact
    end

    def current_duration_ms
      return unless defined?(@call_started_at) && @call_started_at

      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @call_started_at) * 1000).round
    end

    def fallback_provider
      diagnostic_provider = @ai_response_payload.to_h.dig("fallback_diagnostic", "provider")
      diagnostic_provider.presence || (@ai_response_payload.present? ? "ai-service" : nil)
    end

    def decision_from_error_response(response)
      parsed = JSON.parse(response.body)
      return unless parsed.is_a?(Hash) && (parsed["action"].present? || parsed["outcome"].present?)

      @tool_calls = Array(parsed.dig("audit", "tool_calls"))
      DecisionResult.from_hash(parsed)
    rescue JSON::ParserError
      nil
    end

    def rejected_decision_payload(decision)
      return if decision.blank?

      decision.to_h.slice(
        :action,
        :outcome,
        :response_text,
        :safe_fallback_response,
        :language,
        :detected_intents,
        :evidence_ids,
        :used_source_ids,
        :missing_information,
        :safety_flags,
        :confidence,
        :escalation_required,
        :alert_type,
        :owner_task_kind,
        :task_summary,
        :title,
        :owner_task_id,
        :attachments,
        :proposed_action,
        :sensitive_info_used
      )
    end

    def validation_payload(validation, decision)
      status = if validation.valid? && validation.warnings.present?
        "accepted_with_warnings"
      elsif validation.valid?
        "accepted"
      elsif validation.contract_failed?
        "contract_validation_failed"
      elsif validation.reasons.any? { |reason| reason.start_with?("evidence_provenance_violation:") }
        "authorization_rejected"
      elsif validation.reasons.any? { |reason| reason.in?(%w[internal_metadata_visible internal_security_violation sensitive_access_without_authorization]) }
        "security_rejected"
      else
        "rejected"
      end

      {
        status: status,
        passed: validation.valid?,
        failed: !validation.valid?,
        contract_failed: validation.contract_failed?,
        reasons: validation.reasons,
        warnings: validation.warnings,
        evidence: evidence_validation(decision)
      }
    end

    def evidence_validation(decision)
      registry = SourceRegistry.new(conversation: @conversation, guest_message: @guest_message)
      refs = Array(decision.evidence) +
        decision.evidence_ids.map { |evidence_id| { "evidence_id" => evidence_id } } +
        decision.used_source_ids.map { |source_id| { "id" => source_id } }
      attachment_refs = decision.attachments.map { |attachment| { "evidence_id" => attachment["evidence_id"] } }

      (Array(refs) + attachment_refs).uniq { |item| item.to_h.stringify_keys.values_at("id", "evidence_id", "source_id").compact_blank.first }.map do |item|
        evidence_id = item.to_h["id"].presence || item.to_h["evidence_id"].presence || item.to_h["source_id"]
        source = registry.source_for_evidence_id(evidence_id)
        provenance = registry.evidence_provenance(item)
        {
          evidence_id: evidence_id,
          authorized: provenance[:authorized],
          valid: provenance[:authorized],
          provenance_reason: provenance[:reason],
          scope: provenance[:scope],
          conversation_property_id: provenance[:conversation_property_id],
          evidence_property_id: provenance[:property_id],
          conversation_account_id: provenance[:conversation_account_id],
          evidence_account_id: provenance[:account_id],
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
          authorized: validation.fetch(:authorized, validation.fetch("authorized", nil)),
          provenance_reason: validation.fetch(:provenance_reason, validation.fetch("provenance_reason", nil)),
          scope: validation.fetch(:scope, validation.fetch("scope", nil)),
          conversation_property_id: validation.fetch(:conversation_property_id, validation.fetch("conversation_property_id", @property.id)),
          evidence_property_id: validation.fetch(:evidence_property_id, validation.fetch("evidence_property_id", nil)),
          conversation_account_id: validation.fetch(:conversation_account_id, validation.fetch("conversation_account_id", @property.account_id)),
          evidence_account_id: validation.fetch(:evidence_account_id, validation.fetch("evidence_account_id", nil)),
          valid: validation.fetch(:valid, validation.fetch("valid", nil)),
        }
      end
    end

    def decision_evidence_ids(decision)
      ids = decision.evidence_ids +
        decision.used_source_ids +
        decision.evidence.map { |item| item["id"].presence || item["evidence_id"].presence || item["source_id"] } +
        decision.attachments.map { |attachment| attachment["evidence_id"] }
      ids.compact_blank.uniq
    end

    def checkin_trace(decision, evidence_ids, validation_results, fallback_reason)
      return unless @guest_message.body.to_s.match?(AIDecisionLog::CHECKIN_PATTERN)

      tool_names = @tool_calls.map { |tool| tool["tool_name"] || tool["toolName"] || tool[:tool_name] || tool[:toolName] }
      validation_passed = validation_results.to_h[:passed] || validation_results.to_h["passed"]
      tool_evidence_ids = @tool_calls.flat_map do |tool|
        summary = tool["output_summary"] || tool[:output_summary] || {}
        Array(summary["evidence_ids"] || summary[:evidence_ids])
      end
      check_in_evidence = (Array(evidence_ids) + tool_evidence_ids).find { |id| check_in_evidence_id?(id) }

      {
        label: "CHECKIN_TRACE",
        detected_language: decision.language || @fallback_language,
        detected_intents: decision.detected_intents,
        guest_context_called: tool_names.include?("guest_context"),
        stay_facts_called: tool_names.include?("stay_facts") || tool_names.include?("property_brain"),
        check_in_evidence_found: check_in_evidence.present?,
        evidence_id: check_in_evidence.present? ? "property.check_in_time" : nil,
        validation_passed: validation_passed,
        final_response_or_fallback: fallback_reason.presence || decision.response_text
      }
    end

    def check_in_evidence_id?(evidence_id)
      normalized = evidence_id.to_s.downcase.gsub(/[^a-z0-9]/, "")
      normalized.in?(%w[propertycheckintime propertyfactcheckintime])
    end

    def parse_json_or_text(text)
      JSON.parse(text)
    rescue JSON::ParserError
      text.to_s.first(2_000)
    end
  end
end
