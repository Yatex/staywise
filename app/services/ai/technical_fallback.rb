module AI
  class TechnicalFallback
    DEFAULT_MESSAGE = "Estoy teniendo un inconveniente técnico temporal y no pude responder tu consulta. Si es urgente, podés comunicarte con el anfitrión al {{owner_phone}}.".freeze
    FALLBACK_TYPES = %w[
      AI_TIMEOUT
      OPENAI_TIMEOUT
      TOOL_TIMEOUT
      HTTP_TIMEOUT
      NETWORK_ERROR
      OPENAI_ERROR
      TOOL_ERROR
      INTERNAL_EXCEPTION
      UNKNOWN
    ].freeze

    DESCRIPTIONS = {
      "AI_TIMEOUT" => "La solicitud al AI service no recibió respuesta antes del tiempo límite.",
      "OPENAI_TIMEOUT" => "La llamada al modelo superó el tiempo máximo.",
      "TOOL_TIMEOUT" => "La respuesta quedó esperando una tool que excedió el tiempo máximo.",
      "HTTP_TIMEOUT" => "Una solicitud HTTP excedió el tiempo máximo de espera.",
      "NETWORK_ERROR" => "No se pudo completar la comunicación con un servicio externo.",
      "OPENAI_ERROR" => "El proveedor del modelo devolvió un error.",
      "TOOL_ERROR" => "Una tool no pudo completar su ejecución.",
      "INTERNAL_EXCEPTION" => "Se produjo una excepción inesperada durante el procesamiento.",
      "UNKNOWN" => "No fue posible determinar una causa técnica más específica."
    }.freeze

    attr_reader :type

    def initialize(property:, error: nil, response_payload: nil, http_status: nil, duration_ms: nil,
      correlation_id: nil, request_id: nil, provider: nil, tools: [])
      @property = property
      @error = error
      @response_payload = response_payload.to_h.deep_stringify_keys
      @http_status = http_status&.to_i
      @duration_ms = duration_ms
      @correlation_id = correlation_id
      @request_id = request_id
      @provider = provider
      @tools = Array(tools).map { |tool| tool.to_h.deep_stringify_keys }
      @type = classify
    end

    def message
      template = ENV["AI_TECHNICAL_FALLBACK_MESSAGE"].presence || DEFAULT_MESSAGE
      phone = @property.owner_contact_phone.presence || @property.account.owner_whatsapp_number.presence
      return template.gsub("{{owner_phone}}", phone) if phone.present?

      without_phone_sentence(template)
    end

    def diagnostic
      {
        type: type,
        description: DESCRIPTIONS.fetch(type),
        tools_executed: @tools.size,
        tool: affected_tool,
        tool_duration_ms: affected_tool_trace&.dig("latency_ms"),
        duration_ms: @duration_ms,
        fallback_sent: nil,
        message_sent: message,
        exception_class: @error&.class&.name || response_error_class,
        exception_message: @error&.message.presence || response_error_message,
        http_status: @http_status,
        correlation_id: @correlation_id,
        request_id: @request_id,
        provider: @provider,
        timestamp: Time.current.iso8601
      }.compact
    end

    private

    def classify
      return "TOOL_TIMEOUT" if tool_timeout?
      return "OPENAI_TIMEOUT" if model_timeout?
      return "HTTP_TIMEOUT" if @http_status.in?([408, 504])
      return "AI_TIMEOUT" if ai_timeout?
      return "NETWORK_ERROR" if network_error?
      return "TOOL_ERROR" if tool_error?
      return "OPENAI_ERROR" if model_error?
      return "NETWORK_ERROR" if @http_status.present?
      return "INTERNAL_EXCEPTION" if @error.present?

      "UNKNOWN"
    end

    def ai_timeout?
      @error.is_a?(Net::OpenTimeout) || @error.is_a?(Net::ReadTimeout) || @error.is_a?(Timeout::Error)
    end

    def network_error?
      @error.is_a?(SocketError) ||
        @error.is_a?(EOFError) ||
        @error.is_a?(Errno::ECONNRESET) ||
        @error.is_a?(Errno::ECONNREFUSED) ||
        @response_payload["fallback_diagnostic"].to_h["type"] == "NETWORK_ERROR"
    end

    def tool_timeout?
      @response_payload["fallback_diagnostic"].to_h["type"] == "TOOL_TIMEOUT" ||
        @tools.any? { |tool| tool["error"].to_s.match?(/tool_timeout|aborterror|timeouterror/i) }
    end

    def model_timeout?
      @response_payload["fallback_diagnostic"].to_h["type"] == "OPENAI_TIMEOUT" ||
        generate_object_errors.match?(/timeout|aborterror/i)
    end

    def tool_error?
      @response_payload["fallback_diagnostic"].to_h["type"] == "TOOL_ERROR" ||
        @tools.any? { |tool| tool["error"].present? }
    end

    def model_error?
      @response_payload["fallback_diagnostic"].to_h["type"] == "OPENAI_ERROR" ||
        generate_object_errors.present?
    end

    def generate_object_errors
      trace = @response_payload.dig("audit", "generate_object_trace") ||
        @response_payload["generate_object_trace"] ||
        @response_payload.dig("fallback_diagnostic", "details")
      Array(trace).map { |entry| entry.to_h.values_at("error_name", "error_class", "error_message").compact.join(" ") }.join(" ")
    end

    def affected_tool_trace
      @tools.find { |tool| tool["error"].present? }
    end

    def affected_tool
      affected_tool_trace&.dig("tool_name") || @response_payload.dig("fallback_diagnostic", "tool")
    end

    def response_error_class
      @response_payload["error_class"] || @response_payload.dig("fallback_diagnostic", "exception_class")
    end

    def response_error_message
      @response_payload["error_message"] ||
        @response_payload.dig("fallback_diagnostic", "exception_message") ||
        @response_payload["error"]
    end

    def without_phone_sentence(template)
      template
        .gsub(/[^.!?]*\{\{owner_phone\}\}[^.!?]*[.!?]?/i, "")
        .squish
        .presence ||
        "Estoy teniendo un inconveniente técnico temporal y no pude responder tu consulta."
    end
  end
end
