module AI
  class SourceRegistry
    SEARCH_STOPWORDS = %w[
      a al algo como con cual cuales cuando de del donde el en es esta este esto la las le lo los me mi para por q que se si su te tu un una y
      can could how i is it me my of on please the there this to what where with you
      hora horario horarios hours time times quiero quisiera necesito saber decis decime dirias podrias pasarias podrías pasarías
    ].freeze

    PERMISSION_TOKENS = %w[
      aprobar aprobado permiso permitido permitir puedo podrias podrías puede pueden invitar invitados visita visitas gente amigos guests visitors visitor bring allowed allow
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

    SENSITIVE_SOURCE_IDS = {
      "wifi_name" => "sensitive_wifi_name",
      "wifi_password" => "sensitive_wifi_password",
      "access_instructions" => "sensitive_access_instructions"
    }.freeze

    def initialize(conversation:, guest_message: nil)
      @conversation = conversation
      @property = conversation.property
      @guest = conversation.guest
      @guest_message = guest_message || conversation.messages.where(sender: "guest").order(created_at: :desc).first
      @authorization = ReservationAuthorization.new(guest: @guest, property: @property)
    end

    def guest_context(query: nil)
      {
        property: {
          name: @property.display_name,
          timezone: Rails.application.config.time_zone.to_s,
          address_visibility: property_fact("address").present? ? "allowed" : "not_allowed"
        },
        reservation: {
          status: @authorization.reservation_status,
          check_in_date: @guest.check_in_date&.iso8601,
          check_out_date: @guest.checkout_date&.iso8601,
          check_in_time: @property.check_in_time,
          check_out_time: @property.checkout_time,
          guest_is_authorized_for_access: @authorization.sensitive_access_authorized?
        },
        public_facts: SAFE_PROPERTY_FACTS.keys.filter_map { |field| property_fact(field) },
        relevant_faqs: search_property_knowledge(query: query.presence || @guest_message&.body, topic: "faq", limit: 5).select { |source| source["source_type"] == "faq" },
        relevant_guides: search_property_knowledge(query: query.presence || @guest_message&.body, limit: 5).select { |source| source["source_type"] == "knowledge_block" },
        available_capabilities: {
          can_request_early_checkin: true,
          can_request_late_checkout: true,
          can_view_access_instructions: @authorization.sensitive_access_authorized?,
          can_view_wifi: @authorization.sensitive_access_authorized?
        },
        evidence: context_evidence
      }
    end

    def property_brain(guest_message: nil, conversation_summary: nil, limit: 8)
      query = [guest_message.presence || @guest_message&.body, conversation_summary].compact_blank.join(" ")
      matched_sources = property_brain_sources(query: query, limit: limit)

      {
        guest_authorized: @authorization.sensitive_access_authorized?,
        property: {
          id: @property.public_token,
          name: @property.display_name,
          city: nil,
          language: LanguageHelper.owner_language(@property.account)
        },
        stay: {
          status: @authorization.reservation_status,
          check_in_date: @guest.check_in_date&.iso8601,
          check_out_date: @guest.checkout_date&.iso8601,
          check_in_time: @property.check_in_time,
          check_out_time: @property.checkout_time
        },
        matched_sources: matched_sources,
        policies: policies.transform_values { |source| public_source(source) },
        recommendations: property_brain_recommendations(query: query, limit: limit)
      }
    end

    def sensitive_access_info(guest_message: nil)
      unless @authorization.sensitive_access_authorized?
        return {
          authorized: false,
          reason: "guest_not_authorized",
          sources: []
        }
      end

      {
        authorized: true,
        sources: sensitive_access_sources(query: guest_message.presence || @guest_message&.body)
      }
    end

    def property_fact(field)
      source_id = "property_fact:#{field}"
      attribute = SAFE_PROPERTY_FACTS[field.to_s] || SENSITIVE_PROPERTY_FACTS[field.to_s]
      return unless attribute
      return if SENSITIVE_PROPERTY_FACTS.key?(field.to_s) && !@authorization.sensitive_access_authorized?

      value = @property.public_send(attribute).presence
      return if value.blank?

      source("property_fact", source_id, field.to_s, value, record: @property, evidence_id: "property.#{field}")
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

      source("reservation_fact", "reservation_fact:#{field}", field.to_s, value, record: @guest, evidence_id: "reservation.#{field}")
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

      source("faq", "faq:#{faq.id}", faq.question, faq.answer, record: faq, evidence_id: "faq.#{faq.id}")
    end

    def knowledge_source(block)
      return unless block&.property_id == @property.id

      source("knowledge_block", "knowledge_block:#{block.id}", block.title, block.content, record: block, evidence_id: "guide.#{block.id}").merge("category" => block.category)
    end

    def recommendation_source(recommendation)
      return unless recommendation&.property_id == @property.id

      note = [recommendation.description, recommendation.distance_or_walking_time, recommendation.owner_note].compact_blank.join(" ")
      source("recommendation", "recommendation:#{recommendation.id}", recommendation.name, note.presence || recommendation.category, record: recommendation, evidence_id: "recommendation.#{recommendation.id}").merge(
        "category" => recommendation.category,
        "address" => recommendation.address,
        "distance_or_walking_time" => recommendation.distance_or_walking_time,
        "google_maps_url" => recommendation.google_maps_url,
        "website_url" => recommendation.website_url,
        "phone_number" => recommendation.phone_number
      ).compact
    end

    def valid_evidence?(item)
      item = item.to_h.stringify_keys
      source_type = item["source_type"]
      source_id = item["source_id"].to_s
      evidence_id = item["id"].presence || item["evidence_id"].presence || source_id

      case source_type.presence || source_type_from_evidence_id(evidence_id)
      when "property_fact"
        field = property_field_from_reference(evidence_id)
        property_fact(field).present?
      when "reservation_fact"
        field = reservation_field_from_reference(evidence_id)
        reservation_fact(field).present?
      when "faq"
        id = record_id_from_reference(evidence_id, "faq")
        @property.faqs.exists?(id: id)
      when "knowledge_block"
        id = record_id_from_reference(evidence_id, "guide", "knowledge_block")
        @property.knowledge_blocks.exists?(id: id)
      when "recommendation"
        id = record_id_from_reference(evidence_id, "recommendation")
        @property.recommendations.exists?(id: id)
      when "policy"
        policy_field_from_reference(evidence_id).present?
      else
        false
      end
    end

    def valid_evidence_id?(evidence_id)
      valid_evidence?("evidence_id" => evidence_id)
    end

    def relevant_evidence?(item, message)
      item = item.to_h.stringify_keys
      source = evidence_source(item)
      return false if source.blank?

      case item["source_type"].presence || source_type_from_evidence_id(item["id"].presence || item["evidence_id"].presence || item["source_id"])
      when "property_fact", "reservation_fact", "policy"
        fact_relevant?(source, message)
      when "recommendation"
        recommendation_relevant?(source, message)
      when "faq", "knowledge_block"
        knowledge_relevant?(source, message)
      else
        false
      end
    end

    def tool_context
      {
        property_brain: property_brain(guest_message: @guest_message&.body),
        sensitive_access_info: sensitive_access_info(guest_message: @guest_message&.body),
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
      policies[policy_type.to_s] || source("policy", "policy:#{policy_type}", policy_type, "Escalate to the host for approval.", evidence_id: "policy.#{policy_type}")
    end

    private

    def property_brain_sources(query:, limit:)
      candidates = [
        SAFE_PROPERTY_FACTS.keys.filter_map { |field| property_fact(field) },
        reservation_fact("reservation_status"),
        reservation_fact("reservation_dates"),
        policies.values,
        @property.faqs.active.map { |faq| faq_source(faq) },
        @property.knowledge_blocks.active.map { |block| knowledge_source(block) },
        recommendation_candidates_for_brain(query)
      ].flatten.compact

      sources = if query.present?
        search_sources(candidates, query).first(limit)
      else
        candidates.first(limit)
      end

      sources.map { |source| public_source(source) }
    end

    def property_brain_recommendations(query:, limit:)
      return [] unless recommendation_intent?(search_tokens(query))

      sources = @property.recommendations.order(:category, :name).map { |recommendation| recommendation_source(recommendation) }
      sources = search_sources(sources, query) if query.present?
      sources.first(limit).map { |source| public_source(source) }
    end

    def recommendation_candidates_for_brain(query)
      return [] unless recommendation_intent?(search_tokens(query))

      @property.recommendations.order(:category, :name).map { |recommendation| recommendation_source(recommendation) }
    end

    def sensitive_access_sources(query:)
      sources = SENSITIVE_PROPERTY_FACTS.keys.filter_map { |field| property_fact(field) }
      return sources.map { |source| public_source(source) } if query.blank?

      matched = search_sources(sources, query)
      matched = sources if matched.blank?
      matched.map { |source| public_source(source) }
    end

    def public_source(source)
      source.slice(
        "id",
        "type",
        "title",
        "content",
        "confidence",
        "source_type",
        "source_id",
        "evidence_id",
        "label",
        "field",
        "value",
        "excerpt",
        "scope",
        "updated_at",
        "category",
        "address",
        "distance_or_walking_time",
        "google_maps_url",
        "website_url",
        "phone_number"
      ).compact
    end

    def context_evidence
      [
        SAFE_PROPERTY_FACTS.keys.filter_map { |field| property_fact(field) },
        reservation_fact("reservation_status"),
        reservation_fact("reservation_dates"),
        policies.values
      ].flatten.compact
    end

    def evidence_source(item)
      source_id = item["source_id"].to_s
      evidence_id = item["id"].presence || item["evidence_id"].presence || source_id

      case item["source_type"].presence || source_type_from_evidence_id(evidence_id)
      when "property_fact"
        property_fact(property_field_from_reference(evidence_id))
      when "reservation_fact"
        reservation_fact(reservation_field_from_reference(evidence_id))
      when "faq"
        faq = @property.faqs.active.find_by(id: record_id_from_reference(evidence_id, "faq"))
        faq_source(faq)
      when "knowledge_block"
        block = @property.knowledge_blocks.active.find_by(id: record_id_from_reference(evidence_id, "guide", "knowledge_block"))
        knowledge_source(block)
      when "recommendation"
        recommendation = @property.recommendations.find_by(id: record_id_from_reference(evidence_id, "recommendation"))
        recommendation_source(recommendation)
      when "policy"
        property_policy(policy_field_from_reference(evidence_id))
      end
    end

    def source_type_from_evidence_id(evidence_id)
      case evidence_id.to_s
      when /\Aproperty[._]/
        "property_fact"
      when /\Asensitive_/
        "property_fact"
      when /\Areservation[._]/
        "reservation_fact"
      when /\Afaq[._]/
        "faq"
      when /\Aguide[._]/
        "knowledge_block"
      when /\Arecommendation[._]/
        "recommendation"
      when /\Apolicy[._]/
        "policy"
      end
    end

    def authorized_sensitive_facts
      return {} unless @authorization.sensitive_access_authorized?

      SENSITIVE_PROPERTY_FACTS.keys.index_with { |field| property_fact(field) }.compact
    end

    def policies
      {
        "early_checkin" => source("policy", "policy:early_checkin", "early_checkin", "approval_required", evidence_id: "policy.early_checkin"),
        "late_checkout" => source("policy", "policy:late_checkout", "late_checkout", @property.account.late_checkout_policy, evidence_id: "policy.late_checkout"),
        "visitors" => source("policy", "policy:visitors", "visitors", "approval_required", evidence_id: "policy.visitors"),
        "pets" => source("policy", "policy:pets", "pets", "approval_required", evidence_id: "policy.pets"),
        "emergency" => source("policy", "policy:emergency", "emergency", @property.account.emergency_contact_behavior.presence || "Escalate emergencies to the host.", evidence_id: "policy.emergency")
      }
    end

    def source(type, id, label, value, record: nil, evidence_id: nil)
      evidence = evidence_id.presence || id
      modern_id = modern_source_id(type, evidence, label)
      {
        "id" => modern_id,
        "type" => type,
        "title" => label,
        "content" => value.to_s,
        "confidence" => nil,
        "source_type" => type,
        "source_id" => id,
        "evidence_id" => evidence,
        "label" => label,
        "field" => label,
        "value" => value.to_s,
        "excerpt" => value.to_s,
        "scope" => type.to_s.in?(%w[reservation_fact]) ? "reservation" : "property",
        "updated_at" => (record&.updated_at || @property.updated_at).iso8601
      }
    end

    def modern_source_id(type, evidence_id, label)
      case type
      when "property_fact"
        field = property_field_from_reference(evidence_id.presence || label)
        SENSITIVE_SOURCE_IDS[field] || "property_#{field}"
      when "reservation_fact"
        reservation_field_from_reference(evidence_id.presence || label)
      when "faq"
        "faq_#{record_id_from_reference(evidence_id, "faq")}"
      when "knowledge_block"
        "guide_#{record_id_from_reference(evidence_id, "guide", "knowledge_block")}"
      when "recommendation"
        "recommendation_#{record_id_from_reference(evidence_id, "recommendation")}"
      when "policy"
        "policy_#{policy_field_from_reference(evidence_id.presence || label)}"
      else
        evidence_id.to_s.tr(".:", "_")
      end
    end

    def property_field_from_reference(reference)
      value = reference.to_s
      sensitive_match = SENSITIVE_SOURCE_IDS.invert[value]
      return sensitive_match if sensitive_match.present?

      value
        .delete_prefix("property.")
        .delete_prefix("property_")
        .delete_prefix("property_fact:")
    end

    def reservation_field_from_reference(reference)
      value = reference.to_s
      return value if value.in?(%w[reservation_status reservation_dates])

      value
        .delete_prefix("reservation.")
        .delete_prefix("reservation_")
        .delete_prefix("reservation_fact:")
    end

    def record_id_from_reference(reference, *prefixes)
      value = reference.to_s
      prefixes.each do |prefix|
        value = value.delete_prefix("#{prefix}.")
        value = value.delete_prefix("#{prefix}_")
        value = value.delete_prefix("#{prefix}:")
      end
      value.to_i
    end

    def policy_field_from_reference(reference)
      reference.to_s
        .delete_prefix("policy.")
        .delete_prefix("policy_")
        .delete_prefix("policy:")
    end

    def best_record_for(message, records)
      message_tokens = search_tokens(message)
      return if message_tokens.blank? || records.blank?

      scored = records.filter_map do |record|
        source_tokens = search_tokens(yield(record))
        next unless source_matches_intent?(message_tokens, source_tokens)

        score = match_score(message_tokens, source_tokens)
        { record: record, score: score } if score.positive?
      end.sort_by { |item| -item[:score] }

      return if scored.blank?
      return if scored.first[:score] < minimum_match_score(message_tokens)
      return if scored.second && scored.second[:score] == scored.first[:score]

      scored.first[:record]
    end

    def search_sources(sources, query, topic: nil)
      message_tokens = search_tokens(query)
      return [] if message_tokens.blank?

      sources
        .map do |source|
          haystack = [source["label"], source["value"], source["category"], source["source_type"]].compact.join(" ")
          source_tokens = search_tokens(haystack)
          next unless source_matches_intent?(message_tokens, source_tokens)

          score = match_score(message_tokens, source_tokens)
          score += 1 if topic.present? && haystack.downcase.include?(topic.to_s.downcase)
          { source: source, score: score }
        end
        .compact
        .select { |item| item[:score].positive? }
        .select { |item| item[:score] >= minimum_match_score(message_tokens) }
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

    def minimum_match_score(message_tokens)
      meaningful_count = message_tokens.reject { |token| token.in?(%w[direction pool laundry visitors checkin checkout]) }.count
      meaningful_count >= 2 ? 6 : 3
    end

    def source_matches_intent?(message_tokens, source_tokens)
      if message_tokens.include?("visitors")
        return false if (source_tokens & %w[visitors permission]).blank?
      end

      true
    end

    def knowledge_relevant?(source, message)
      message_tokens = search_tokens(message)
      source_tokens = search_tokens([source["label"], source["value"], source["category"]].join(" "))
      return false unless source_matches_intent?(message_tokens, source_tokens)

      match_score(message_tokens, source_tokens) >= minimum_match_score(message_tokens)
    end

    def recommendation_relevant?(source, message)
      message_tokens = search_tokens(message)
      return false unless recommendation_intent?(message_tokens)

      source_tokens = search_tokens([source["label"], source["value"], source["category"]].join(" "))
      match_score(message_tokens, source_tokens).positive?
    end

    def fact_relevant?(source, message)
      field = source["label"].to_s
      text = ActiveSupport::Inflector.transliterate(message.to_s.downcase)

      case field
      when "check_in_time"
        text.match?(/check.?in|entrada|ingreso/) ||
          (text.match?(/llegar|arrival|arrive/) && time_question?(text))
      when "check_out_time"
        text.match?(/check.?out|checkout|salida|salir|leave|departure/)
      when "address"
        text.match?(/address|direccion|ubicacion|como llego|llegar al edificio|guia|maps|mapa/)
      when "parking"
        text.match?(/parking|garage|estacionamiento|cochera/)
      when "rules"
        text.match?(/house rules|rules|reglas|normas/)
      when "wifi_name", "wifi_password"
        text.match?(/wifi|wi-fi|password|contrasena|contraseña|red/)
      when "access_instructions"
        text.match?(/access|entrada|acceso|cerradura|codigo|código|llave|porton|portón|como llego|guia/)
      else
        knowledge_relevant?(source, message)
      end
    end

    def recommendation_intent?(tokens)
      (tokens & %w[
        restaurant cafe supermarket pharmacy attraction transport recommendation recommendations
        comer cenar almorzar desayuno supermercado farmacia transporte visitar lugar lugares
        exchange cambio dinero pesos western union
      ]).any?
    end

    def time_question?(text)
      text.match?(/hora|horario|time|when|cu[aá]ndo|cuando/)
    end

    def search_tokens(value)
      normalized = ActiveSupport::Inflector.transliterate(value.to_s.downcase)
        .gsub(/check[\s_-]*in/, "checkin")
        .gsub(/check[\s_-]*out/, "checkout")

      tokens = normalized
        .gsub(/\bq\b/, " que ")
        .scan(/[a-z0-9]+/)
        .reject { |word| word.length < 4 || SEARCH_STOPWORDS.include?(word) }

      expand_tokens(tokens).uniq
    end

    def expand_tokens(tokens)
      expanded = tokens.dup

      expanded << "direction" if (tokens & %w[llego llegar guia ubicacion direccion acceder acceso bajar bajo subir edificio maps mapa route directions]).any?
      expanded << "pool" if (tokens & %w[pileta piscina pool]).any?
      expanded << "laundry" if (tokens & %w[lavadero lavarropas laundry laundromat washing washer]).any?
      expanded << "visitors" if (tokens & %w[invitar invitados visita visitas gente amigos guests visitors visitor friends bring]).any?
      expanded << "permission" if (tokens & PERMISSION_TOKENS).any?
      expanded << "checkin" if (tokens & %w[checkin entrada ingreso arrival arrive llegar]).any?
      expanded << "checkout" if (tokens & %w[checkout salida salir leave departure]).any?
      expanded.concat(%w[late late_checkout]) if tokens.include?("checkout") && (tokens & %w[tarde later late extender extenderla extension]).any?

      expanded
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
