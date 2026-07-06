class AIDecisionLog < ApplicationRecord
  SENSITIVE_KEYS = /(authorization|token|secret|password|wifi_password|auth|api_key|key|code|lockbox|access_code|door_code)/i
  SENSITIVE_TEXT_KEYS = /(password|wifi|wi-fi|contrase|clave|code|c[oó]digo|lockbox|access|acceso|door|puerta|key|llave)/i
  CHECKIN_PATTERN = /(check[\s-]?in|checkin|ingreso|entrada|arriv[ée]e|arrivée)/i
  REDACTED = "[REDACTED]".freeze

  belongs_to :account, optional: true
  belongs_to :property, optional: true
  belongs_to :guest, optional: true
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true
  belongs_to :original_message, class_name: "Message", optional: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :with_fallback, -> { where.not(fallback_reason: [nil, ""]) }
  scope :validation_failed, -> { where("validation_results ->> 'status' = ?", "rejected").or(where(validator_result: "rejected")) }

  def self.sanitize_trace(value, parent_key = nil)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, item), result|
        key_string = key.to_s
        result[key_string] = sensitive_key?(key_string) ? REDACTED : sanitize_trace(item, key_string)
      end
    when Array
      value.map { |item| sanitize_trace(item, parent_key) }
    when String
      sensitive_text_key?(parent_key) ? mask_sensitive_string(value) : mask_sensitive_fragments(value)
    else
      value
    end
  end

  def fallback?
    fallback_reason.present? || safety_flags.include?("fallback") || route.to_s.include?("fallback")
  end

  def validation_failed?
    validator_result == "rejected" || validation_results.to_h["status"] == "rejected"
  end

  def checkin_trace
    payload.to_h["checkin_trace"].presence || {}
  end

  private_class_method def self.sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEYS)
  end

  private_class_method def self.sensitive_text_key?(key)
    key.to_s.match?(SENSITIVE_TEXT_KEYS)
  end

  private_class_method def self.mask_sensitive_string(value)
    return value if value.blank?
    return REDACTED if value.length <= 4

    "#{value.first(2)}#{'*' * [value.length - 4, 4].max}#{value.last(2)}"
  end

  private_class_method def self.mask_sensitive_fragments(value)
    value
      .gsub(/((?:wifi[_\s-]?password|wi-fi[_\s-]?password|contrase(?:ñ|n)a(?:\s+de\s+wifi)?|clave(?:\s+de\s+wifi)?|password|access[_\s-]?code|door[_\s-]?code|lockbox[_\s-]?code|c[oó]digo(?:\s+de\s+acceso)?)["']?\s*[:=]\s*["']?)([^"',;\n]+)/i, "\\1#{REDACTED}")
      .gsub(/("(?:wifi_password|password|access_code|door_code|lockbox_code|secret|token|authorization)"\s*:\s*")([^"]+)(")/i, "\\1#{REDACTED}\\3")
  end
end
