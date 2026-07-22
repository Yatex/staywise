class ErrorReporter
  FILTERED_KEYS = %w[
    password
    password_confirmation
    token
    authorization
    signature
    stripe_signature
    twilio_auth_token
    api_key
    secret
  ].freeze
  SENTRY_CONTEXT_KEYS = %w[
    account_id property_id conversation_id ai_trace_id message_id request_id
    action controller tool_name evidence_count status error_code provider
    actor_role actor_id item_type item_id
    record_model record_error_attributes template_sid variable_keys expected_variable_keys
    ai_service_attempts
  ].freeze

  def self.report(error = nil, source:, severity: "error", account: nil, property: nil, message: nil, context: {})
    new(
      error: error,
      source: source,
      severity: severity,
      account: account,
      property: property,
      message: message,
      context: context
    ).report
  end

  def initialize(error:, source:, severity:, account:, property:, message:, context:)
    @error = error
    @source = source
    @severity = severity
    @account = account
    @property = property
    @message = message
    @context = context
  end

  def report
    report_to_sentry
    OperationalError.create!(
      account: @account,
      property: @property,
      source: @source.to_s,
      severity: normalized_severity,
      error_class: @error&.class&.name,
      message: @message.presence || @error&.message.presence || "Operational error",
      context: sanitized_context
    )
  rescue StandardError => reporter_error
    Rails.logger.error("[error-reporter] #{reporter_error.class}: #{reporter_error.message}")
    nil
  end

  private

  def report_to_sentry
    return unless defined?(Sentry) && Sentry.initialized?

    Sentry.with_scope do |scope|
      scope.set_level(normalized_severity)
      scope.set_tags({
        source: @source.to_s,
        account_id: @account&.id,
        property_id: @property&.id,
        request_id: Current.request_id
      }.compact)
      scope.set_context("operation", sentry_context)
      if @error
        Sentry.capture_exception(@error)
      else
        Sentry.capture_message(@message.presence || "Operational error")
      end
    end
  rescue StandardError => sentry_error
    Rails.logger.debug("[sentry-reporter] #{sentry_error.class}: #{sentry_error.message}")
  end

  def sentry_context
    sanitized_context.slice(*SENTRY_CONTEXT_KEYS)
  end

  def normalized_severity
    OperationalError::SEVERITIES.include?(@severity.to_s) ? @severity.to_s : "error"
  end

  def sanitized_context
    sanitize((@context || {}).to_h.deep_stringify_keys.merge(active_record_error_context))
  end

  def sanitize(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key] = sensitive_key?(key.to_s) ? "[FILTERED]" : sanitize(item)
      end
    when Array
      value.map { |item| sanitize(item) }
    else
      value
    end
  end

  def sensitive_key?(key)
    FILTERED_KEYS.any? { |filtered| key.downcase.include?(filtered) }
  end

  def active_record_error_context
    return {} unless @error.is_a?(ActiveRecord::RecordInvalid) && @error.record

    {
      "record_model" => @error.record.class.name,
      "record_error_attributes" => @error.record.errors.attribute_names.map(&:to_s),
      "record_errors" => @error.record.errors.full_messages
    }
  end
end
