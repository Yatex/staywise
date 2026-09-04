module Copilot
  class DraftService
    HISTORY_LIMIT = 12

    Result = Struct.new(:successful, :run, :assistant_message, :error, keyword_init: true) do
      def success?
        successful
      end
    end

    def self.call(thread:, content:, host_context: nil, client: AIClient.new)
      new(thread: thread, content: content, host_context: host_context, client: client).call
    end

    def initialize(thread:, content:, host_context:, client:)
      @thread = thread
      @content = content.to_s.strip
      @host_context = host_context.to_s.strip.presence
      @client = client
    end

    def call
      raise ArgumentError, "El mensaje del huésped es obligatorio." if @content.blank?

      host_message = create_host_message!
      run = create_run!(host_message)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @client.call(payload_for(host_message, run))
      contract = ResponseContract.from_hash(response)
      assistant_message = persist_success!(run, contract, response, started_at)
      Result.new(successful: true, run: run, assistant_message: assistant_message, error: nil)
    rescue AIClient::Error, ResponseContract::InvalidResponse => error
      persist_failure!(run, error, started_at) if run
      Result.new(successful: false, run: run, assistant_message: nil, error: error)
    end

    private

    def create_host_message!
      @thread.copilot_messages.create!(
        account: @thread.account,
        property: @thread.property,
        user: @thread.user,
        role: "host",
        content: @content,
        host_context: @host_context
      ).tap { |message| @thread.update!(last_message_at: message.created_at) }
    end

    def create_run!(message)
      @thread.copilot_runs.create!(
        copilot_message: message,
        account: @thread.account,
        property: @thread.property,
        user: @thread.user,
        status: "pending",
        correlation_id: Current.request_id.presence || SecureRandom.uuid
      )
    end

    def payload_for(message, run)
      base_url = ENV["AI_TOOLS_BASE_URL"].presence || ENV["APP_HOST"].presence
      {
        correlation_id: run.correlation_id,
        account_id: @thread.account_id,
        property_id: @thread.property_id,
        user_id: @thread.user_id,
        thread_id: @thread.id,
        property: { name: @thread.property.display_name },
        guest_message: message.content,
        host_context: message.host_context,
        owner_language: "es",
        thread_history: history_before(message),
        tool_endpoint: base_url.present? ? {
          base_url: base_url,
          path_prefix: "/internal/ai/copilot_tools",
          decision_context_id: ToolContext.issue(thread: @thread, message: message),
          correlation_id: run.correlation_id
        } : nil
      }
    end

    def history_before(message)
      @thread.copilot_messages.where.not(id: message.id).order(created_at: :desc).limit(HISTORY_LIMIT).to_a.reverse.map do |item|
        {
          role: item.role,
          content: item.content,
          host_context: item.host_context,
          structured_content: item.role == "assistant" ? item.structured_content : nil
        }.compact
      end
    end

    def persist_success!(run, contract, response, started_at)
      attributes = contract.to_h
      assistant_message = nil
      CopilotRun.transaction do
        run.update!(attributes.merge(
          status: "completed",
          tool_calls: Array(response.dig("audit", "tool_calls")),
          latency_ms: elapsed_ms(started_at)
        ))
        content = contract.guest_reply.presence || contract.clarifying_question_guest.presence || contract.clarifying_question_es
        assistant_message = @thread.copilot_messages.create!(
          account: @thread.account,
          property: @thread.property,
          user: @thread.user,
          role: "assistant",
          content: content,
          structured_content: attributes
        )
        @thread.update!(
          title: @thread.title.presence || contract.guest_question_es.truncate(80),
          last_message_at: assistant_message.created_at
        )
      end
      persist_trace(run, response, "copilot_completed")
      assistant_message
    end

    def persist_failure!(run, error, started_at)
      type = error.respond_to?(:type) ? error.type : "malformed_response"
      run.update!(status: "failed", error_type: type, error_message: error.message, latency_ms: elapsed_ms(started_at))
      response = error.respond_to?(:response_payload) ? error.response_payload : nil
      persist_trace(run, response, "copilot_failed")
    end

    def persist_trace(run, response, route)
      AIDecisionLog.create!(
        account: run.account,
        property: run.property,
        copilot_run: run,
        route: route,
        decision: route == "copilot_completed" ? "copilot_reply" : "copilot_error",
        language: run.detected_language,
        validator_result: route == "copilot_completed" ? "accepted" : "rejected",
        latency_ms: run.latency_ms,
        model: ENV["AI_MODEL"],
        evidence_ids: run.evidence_refs,
        missing_information: run.missing_information? ? [run.clarifying_question_es] : [],
        ai_request_payload: AIDecisionLog.sanitize_trace(trace_request_payload(run)),
        ai_response_payload: AIDecisionLog.sanitize_trace(response || {}),
        tool_calls: AIDecisionLog.sanitize_trace(run.tool_calls),
        fallback_reason: nil,
        final_outcome: route,
        payload: AIDecisionLog.sanitize_trace(
          copilot_thread_id: run.copilot_thread_id,
          copilot_run_id: run.id,
          missing_information: run.missing_information,
          error_type: run.error_type,
          correlation_id: run.correlation_id
        )
      )
    rescue StandardError => error
      Rails.logger.warn("[copilot-audit] persist_failed #{error.class}: #{error.message}")
    end

    def trace_request_payload(run)
      message = run.copilot_message
      {
        endpoint: "/copilot",
        account_id: run.account_id,
        property: { id: run.property_id, name: run.property.display_name },
        user: { id: run.user_id, email: run.user.email },
        thread_id: run.copilot_thread_id,
        guest_message: message.content,
        host_context: message.host_context,
        thread_history: history_before(message)
      }
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round
    end
  end
end
