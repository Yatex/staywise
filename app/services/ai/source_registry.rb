module AI
  class SourceRegistry
    SAFE_PROPERTY_FACTS = {
      "check_in_time" => :check_in_time,
      "check_out_time" => :checkout_time,
      "address" => :address,
      "parking" => :parking_instructions,
      "rules" => :house_rules,
      "emergency_information" => :emergency_information
    }.freeze

    SENSITIVE_PROPERTY_FACTS = {
      "wifi_name" => :wifi_name,
      "wifi_password" => :wifi_password,
      "access_instructions" => :access_instructions
    }.freeze

    def initialize(conversation:)
      @conversation = conversation
      @property = conversation.property
      @guest = conversation.guest
      @authorization = ReservationAuthorization.new(guest: @guest, property: @property)
    end

    def property_fact(field)
      source_id = "property_fact:#{field}"
      attribute = SAFE_PROPERTY_FACTS[field.to_s] || SENSITIVE_PROPERTY_FACTS[field.to_s]
      return unless attribute
      return if SENSITIVE_PROPERTY_FACTS.key?(field.to_s) && !@authorization.sensitive_access_authorized?

      value = @property.public_send(attribute).presence
      return if value.blank?

      source("property_fact", source_id, field.to_s, value)
    end

    def reservation_fact(field)
      value =
        case field.to_s
        when "reservation_dates"
          [@guest.check_in_date, @guest.checkout_date].compact.join(" to ")
        when "reservation_status"
          @authorization.reservation_status
        end
      return if value.blank?

      source("reservation_fact", "reservation_fact:#{field}", field.to_s, value)
    end

    def exact_faq_for(message)
      normalized = normalize(message)
      return if normalized.blank?

      @property.faqs.active.find do |faq|
        normalize(faq.question) == normalized
      end
    end

    def faq_source(faq)
      return unless faq&.property_id == @property.id

      source("faq", "faq:#{faq.id}", faq.question, faq.answer)
    end

    def knowledge_source(block)
      return unless block&.property_id == @property.id

      source("knowledge_block", "knowledge_block:#{block.id}", block.title, block.content)
    end

    def recommendation_source(recommendation)
      return unless recommendation&.property_id == @property.id

      note = [recommendation.description, recommendation.distance_or_walking_time, recommendation.owner_note].compact_blank.join(" ")
      source("recommendation", "recommendation:#{recommendation.id}", recommendation.name, note.presence || recommendation.category)
    end

    def valid_evidence?(item)
      item = item.to_h.stringify_keys
      source_type = item["source_type"]
      source_id = item["source_id"].to_s

      case source_type
      when "property_fact"
        field = source_id.delete_prefix("property_fact:")
        property_fact(field).present?
      when "reservation_fact"
        field = source_id.delete_prefix("reservation_fact:")
        reservation_fact(field).present?
      when "faq"
        id = source_id.delete_prefix("faq:").to_i
        @property.faqs.exists?(id: id)
      when "knowledge_block"
        id = source_id.delete_prefix("knowledge_block:").to_i
        @property.knowledge_blocks.exists?(id: id)
      when "recommendation"
        id = source_id.delete_prefix("recommendation:").to_i
        @property.recommendations.exists?(id: id)
      when "policy"
        source_id.start_with?("policy:")
      else
        false
      end
    end

    def tool_context
      {
        safe_property_facts: SAFE_PROPERTY_FACTS.keys.index_with { |field| property_fact(field) }.compact,
        reservation_facts: {
          "reservation_status" => reservation_fact("reservation_status"),
          "reservation_dates" => reservation_fact("reservation_dates")
        }.compact,
        sensitive_access_authorized: @authorization.sensitive_access_authorized?,
        sensitive_property_facts: authorized_sensitive_facts,
        faqs: @property.faqs.active.order(:category, :question).map { |faq| faq_source(faq) },
        knowledge_blocks: @property.knowledge_blocks.active.order(:category, :title).map { |block| knowledge_source(block) },
        recommendations: @property.recommendations.order(:category, :name).map { |recommendation| recommendation_source(recommendation) },
        policies: policies
      }
    end

    private

    def authorized_sensitive_facts
      return {} unless @authorization.sensitive_access_authorized?

      SENSITIVE_PROPERTY_FACTS.keys.index_with { |field| property_fact(field) }.compact
    end

    def policies
      {
        "late_checkout" => source("policy", "policy:late_checkout", "late_checkout", @property.account.late_checkout_policy),
        "emergency" => source("policy", "policy:emergency", "emergency", @property.account.emergency_contact_behavior.presence || "Escalate emergencies to the host.")
      }
    end

    def source(type, id, label, value)
      {
        "source_type" => type,
        "source_id" => id,
        "label" => label,
        "value" => value.to_s
      }
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9áéíóúüñ]+/i, " ").squish
    end
  end
end
