class AIDecisionLog < ApplicationRecord
  SENSITIVE_KEYS = /(authorization|token|secret|password|wifi_password|auth|api_key|key|code|lockbox|access_code|door_code)/i
  SENSITIVE_TEXT_KEYS = /(password|wifi|wi-fi|contrase|clave|code|c[oó]digo|lockbox|access|acceso|door|puerta|key|llave)/i
  SENSITIVE_EVIDENCE_DESCRIPTOR = /(sensitive|password|wifi_(?:name|password)|contrase|clave|(?:access|door|gate|alarm|lockbox|building_access)_code|access_instructions|key_location|device_password|c[oó]digo)/i
  CHECKIN_PATTERN = /(check[\s-]?in|checkin|ingreso|entrada|arriv[ée]e|arrivée)/i
  REDACTED = "[REDACTED]".freeze

  belongs_to :account, optional: true
  belongs_to :property, optional: true
  belongs_to :guest, optional: true
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true
  belongs_to :original_message, class_name: "Message", optional: true
  belongs_to :copilot_run, optional: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :with_fallback, -> { where.not(fallback_reason: [nil, ""]) }
  scope :validation_failed, -> {
    where("validation_results ->> 'failed' = ?", "true")
      .or(where(validator_result: %w[rejected contract_validation_failed]))
  }

  def self.sanitize_trace(value, parent_key = nil)
    case value
    when Hash
      sensitive_evidence = sensitive_evidence_hash?(value)
      value.to_h.each_with_object({}) do |(key, item), result|
        key_string = key.to_s
        result[key_string] = if sensitive_key?(key_string) || (sensitive_evidence && evidence_content_key?(key_string))
          REDACTED
        else
          sanitize_trace(item, key_string)
        end
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
    if has_attribute?("fallback_summary")
      return ActiveModel::Type::Boolean.new.cast(self[:fallback_summary])
    end

    fallback_reason.present? || safety_flags.include?("fallback") || route.to_s.include?("fallback")
  end

  def validation_failed?
    if has_attribute?("validation_failed_summary")
      return ActiveModel::Type::Boolean.new.cast(self[:validation_failed_summary])
    end

    validation_results.to_h["failed"] == true ||
      validator_result.in?(%w[rejected contract_validation_failed]) ||
      validation_results.to_h["status"].in?(%w[rejected contract_validation_failed evidence_provenance_rejected authorization_rejected security_rejected])
  end

  def checkin_trace
    payload.to_h["checkin_trace"].presence || {}
  end

  private_class_method def self.sensitive_key?(key)
    return false if key.to_s.in?(%w[authorized provenance_authorized])

    key.to_s == "decision_context_id" || key.to_s.match?(SENSITIVE_KEYS)
  end

  private_class_method def self.sensitive_evidence_hash?(value)
    hash = value.to_h.stringify_keys
    descriptor = [
      hash["field"],
      hash["label"],
      hash["title"],
      hash["source_type"],
      hash["type"],
      hash["sensitivity"]
    ].compact.join(" ")

    descriptor.match?(SENSITIVE_EVIDENCE_DESCRIPTOR)
  end

  private_class_method def self.evidence_content_key?(key)
    key.to_s.in?(%w[value content excerpt text preview])
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
