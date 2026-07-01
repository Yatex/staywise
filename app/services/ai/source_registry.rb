module AI
  class SourceRegistry
    SEARCH_STOPWORDS = %w[
      a al algo como con cual cuales cuando de del donde el en es esta este esto la las le lo los me mi para por q que se si su te tu un una y
      can could how i is it me my of on please the there this to what where with you
    ].freeze

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

    def best_faq_for(message)
      best_record_for(message, @property.faqs.active.to_a) do |faq|
        [faq.question, faq.answer, faq.category].compact.join(" ")
      end
    end

    def best_knowledge_block_for(message)
      best_record_for(message, @property.knowledge_blocks.active.to_a) do |block|
        [block.title, block.category, block.content].compact.join(" ")
      end
    end

    def faq_source(faq)
      return unless faq&.property_id == @property.id

      source("faq", "faq:#{faq.id}", faq.question, faq.answer)
    end

    def knowledge_source(block)
      return unless block&.property_id == @property.id

      source("knowledge_block", "knowledge_block:#{block.id}", block.title, block.content).merge("category" => block.category)
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

    def stay_facts(requested_fields)
      Array(requested_fields).filter_map do |field|
        case field.to_s
        when "reservation_dates", "reservation_status"
          reservation_fact(field)
        else
          property_fact(field)
        end
      end
    end

    def search_property_knowledge(query:, topic: nil, limit: 5)
      candidates = @property.faqs.active.map { |faq| faq_source(faq) } +
        @property.knowledge_blocks.active.map { |block| knowledge_source(block) }

      search_sources(candidates, query, topic: topic).first(limit)
    end

    def approved_recommendations(category:, limit: 5)
      normalized_category = normalize_recommendation_category(category)
      scope = @property.recommendations.order(:category, :name)
      scope = scope.where(category: normalized_category) if normalized_category.present?

      scope.limit(limit).map { |recommendation| recommendation_source(recommendation) }
    end

    def access_instructions
      return { denied: true, reason: "Sensitive access is not authorized for this guest/reservation window." } unless @authorization.sensitive_access_authorized?

      authorized_sensitive_facts.values
    end

    def property_policy(policy_type)
      policies[policy_type.to_s] || source("policy", "policy:#{policy_type}", policy_type, "Escalate to the host for approval.")
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

    def best_record_for(message, records)
      message_tokens = search_tokens(message)
      return if message_tokens.blank? || records.blank?

      scored = records.filter_map do |record|
        source_tokens = search_tokens(yield(record))
        score = match_score(message_tokens, source_tokens)
        { record: record, score: score } if score.positive?
      end.sort_by { |item| -item[:score] }

      return if scored.blank?
      return if scored.first[:score] < 2
      return if scored.second && scored.second[:score] == scored.first[:score]

      scored.first[:record]
    end

    def search_sources(sources, query, topic: nil)
      message_tokens = search_tokens(query)
      return [] if message_tokens.blank?

      sources
        .map do |source|
          haystack = [source["label"], source["value"], source["category"], source["source_type"]].compact.join(" ")
          score = match_score(message_tokens, search_tokens(haystack))
          score += 1 if topic.present? && haystack.downcase.include?(topic.to_s.downcase)
          { source: source, score: score }
        end
        .select { |item| item[:score].positive? }
        .sort_by { |item| -item[:score] }
        .map { |item| item[:source] }
    end

    def normalize_recommendation_category(category)
      case category.to_s
      when "breakfast", "coffee"
        "cafe"
      when "activities"
        "attraction"
      else
        category.to_s.presence
      end
    end

    def match_score(message_tokens, source_tokens)
      message_tokens.sum do |message_token|
        if source_tokens.include?(message_token)
          3
        elsif message_token.length >= 5 && source_tokens.any? { |source_token| source_token.length >= 5 && edit_distance_at_most_one?(message_token, source_token) }
          2
        else
          0
        end
      end
    end

    def search_tokens(value)
      ActiveSupport::Inflector.transliterate(value.to_s.downcase)
        .gsub(/\bq\b/, " que ")
        .scan(/[a-z0-9]+/)
        .reject { |word| word.length < 4 || SEARCH_STOPWORDS.include?(word) }
        .uniq
    end

    def edit_distance_at_most_one?(left, right)
      return true if left == right
      return false if (left.length - right.length).abs > 1

      i = 0
      j = 0
      edits = 0

      while i < left.length && j < right.length
        if left[i] == right[j]
          i += 1
          j += 1
        elsif edits.zero?
          edits += 1
          if left.length > right.length
            i += 1
          elsif right.length > left.length
            j += 1
          else
            i += 1
            j += 1
          end
        else
          return false
        end
      end

      edits + (left.length - i) + (right.length - j) <= 1
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9áéíóúüñ]+/i, " ").squish
    end
  end
end
