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

  def normalized_severity
    OperationalError::SEVERITIES.include?(@severity.to_s) ? @severity.to_s : "error"
  end

  def sanitized_context
    sanitize((@context || {}).to_h.deep_stringify_keys)
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
end
