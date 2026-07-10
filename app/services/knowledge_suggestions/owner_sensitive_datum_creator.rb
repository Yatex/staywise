module KnowledgeSuggestions
  class OwnerSensitiveDatumCreator
    SENSITIVE_LABELS = {
      "property.safe_code" => "safe_code",
      "property.lockbox_code" => "lockbox_code",
      "property.door_code" => "door_code",
      "property.gate_code" => "gate_code",
      "property.alarm_code" => "alarm_code",
      "property.building_access_code" => "building_access_code",
      "property.key_location" => "key_location",
      "property.device_password" => "device_password"
    }.freeze

    TITLE_PATTERNS = {
      "safe_code" => /caja fuerte|safe/i,
      "lockbox_code" => /caja de llaves|lockbox|keybox/i,
      "door_code" => /puerta|door/i,
      "gate_code" => /port[oó]n|gate|garage|cochera/i,
      "alarm_code" => /alarma|alarm/i,
      "building_access_code" => /edificio|building|hall/i,
      "key_location" => /ubicaci[oó]n de llaves|llaves|key location/i,
      "device_password" => /dispositivo|device|netflix|tv/i
    }.freeze

    def self.call(alert:, owner_answer:, owner_message:)
      new(alert: alert, owner_answer: owner_answer, owner_message: owner_message).call
    end

    def initialize(alert:, owner_answer:, owner_message:)
      @alert = alert
      @owner_answer = owner_answer.to_s.strip
      @owner_message = owner_message
    end

    def call
      return if @alert.blank? || @owner_answer.blank?

      kind = requested_kind
      return if kind.blank?

      datum = @alert.property.sensitive_data.active.find_or_initialize_by(kind: kind)
      datum.value = @owner_answer
      datum.source_alert = @alert
      datum.metadata = datum.metadata.merge(
        "source_type" => "owner_alert_answer",
        "alert_id" => @alert.id,
        "conversation_id" => @alert.conversation_id,
        "guest_id" => @alert.guest_id,
        "owner_message_id" => @owner_message&.id,
        "updated_from_owner_answer_at" => Time.current.iso8601
      ).compact
      datum.save!

      append_trace_learning_event(datum)
      datum
    end

    private

    def requested_kind
      return unless @alert.alert_type == "missing_sensitive_information"

      requested_from_metadata ||
        requested_from_missing_information ||
        requested_from_text
    end

    def requested_from_metadata
      candidates = [
        @alert.metadata.to_h["requested_sensitive_type"],
        @alert.metadata.to_h["missing_sensitive_type"],
        @alert.metadata.to_h.dig("decision", "missing_sensitive_type")
      ]
      candidates.filter_map { |value| normalize_kind(value) }.first
    end

    def requested_from_missing_information
      Array(@alert.metadata.to_h["missing_information"]).filter_map { |value| normalize_kind(value) }.first ||
        Array(@alert.metadata.to_h["detected_intents"]).filter_map { |intent| normalize_kind(intent.to_h["requested_sensitive_type"]) }.first
    end

    def requested_from_text
      haystack = [@alert.title, @alert.description, @alert.original_message&.body].compact.join(" ")
      TITLE_PATTERNS.find { |_kind, pattern| haystack.match?(pattern) }&.first
    end

    def normalize_kind(value)
      normalized = value.to_s.strip
      normalized = SENSITIVE_LABELS.fetch(normalized, normalized)
      normalized = normalized.delete_prefix("property.")
      return normalized if PropertySensitiveDatum::KINDS.include?(normalized)
    end

    def append_trace_learning_event(datum)
      return if @alert.ai_decision_log.blank?

      payload = @alert.ai_decision_log.payload.to_h
      @alert.ai_decision_log.update!(
        payload: payload.merge(
          "sensitive_datum_learning" => {
            "created_or_updated" => true,
            "property_sensitive_datum_id" => datum.id,
            "kind" => datum.kind,
            "source_type" => "owner_alert_answer",
            "property_id" => @alert.property_id
          }
        )
      )
    rescue StandardError => error
      Rails.logger.warn("[owner-alert-learning] sensitive_trace_update_failed #{error.class}: #{error.message}")
    end
  end
end
