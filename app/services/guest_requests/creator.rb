module GuestRequests
  class Creator
    REQUEST_ACTION_TYPES = {
      "request_food_or_drink" => "food_or_drink",
      "guest_request_food_or_drink" => "food_or_drink",
      "request_extra_bed" => "extra_bed",
      "guest_request_extra_bed" => "extra_bed",
      "request_extra_item" => "extra_item",
      "guest_request_extra_item" => "extra_item",
      "request_service" => "service",
      "guest_request_service" => "service",
      "request_transport" => "transport",
      "guest_request_transport" => "transport",
      "request_late_checkout" => "late_checkout",
      "late_checkout_request" => "late_checkout",
      "request_early_checkin" => "early_checkin",
      "early_checkin_request" => "early_checkin",
      "request_reservation_extension" => "reservation_change",
      "guest_request" => "other",
      "request_other" => "other",
      "guest_request_other" => "other"
    }.freeze

    INTENT_CATEGORIES = {
      "guest_request" => "other",
      "request_extra_item" => "extra_item",
      "request_service" => "service",
      "request_late_checkout" => "late_checkout",
      "late_checkout" => "late_checkout",
      "request_early_checkin" => "early_checkin",
      "early_checkin" => "early_checkin",
      "request_extra_bed" => "extra_bed",
      "request_food_or_drink" => "food_or_drink",
      "request_transport" => "transport",
      "request_other" => "other"
    }.freeze

    TITLE_BY_CATEGORY = {
      "food_or_drink" => "Pedido de comida o bebida",
      "extra_bed" => "Pedido de cama extra",
      "extra_item" => "Pedido de artículo extra",
      "service" => "Pedido de servicio",
      "transport" => "Pedido de transporte",
      "late_checkout" => "Pedido de late checkout",
      "early_checkin" => "Pedido de early check-in",
      "reservation_change" => "Pedido de cambio de reserva",
      "other" => "Pedido del huésped"
    }.freeze

    def self.call(conversation:, decision:, guest_message:)
      new(conversation: conversation, decision: decision, guest_message: guest_message).call
    end

    def initialize(conversation:, decision:, guest_message:)
      @conversation = conversation
      @decision = decision
      @guest_message = guest_message
    end

    def call
      category = request_category
      return unless category

      if (request = existing_request(category))
        update_request!(request)
      else
        create_request(category)
      end
    end

    private

    def request_category
      action_type = @decision.proposed_action.to_h["type"].to_s
      return REQUEST_ACTION_TYPES[action_type] if REQUEST_ACTION_TYPES.key?(action_type)

      categories = detected_intents.filter_map do |intent|
        INTENT_CATEGORIES[intent["type"].to_s]
      end

      categories.find { |category| category != "other" } || categories.first
    end

    def detected_intents
      @decision.detected_intents.map(&:to_h).map(&:stringify_keys)
    end

    def existing_request(category)
      GuestRequest.find_by(message: @guest_message) ||
        @conversation.guest_requests.open.where(
          account: @conversation.property.account,
          property: @conversation.property,
          guest: @conversation.guest,
          category: category
        ).where("created_at >= ?", 24.hours.ago).order(updated_at: :desc).first
    end

    def update_request!(request)
      return request if request.message_id == @guest_message.id

      updates = Array(request.metadata["updates"])
      updates << {
        "message_id" => @guest_message.id,
        "body" => request_text,
        "received_at" => @guest_message.created_at.iso8601,
        "changed_field" => inferred_update_field
      }.compact

      request.update!(
        ai_decision_log: request.ai_decision_log || latest_ai_trace,
        ai_summary: [request.ai_summary, ai_summary].compact_blank.uniq.join("\n"),
        structured_details: request.structured_details.merge(structured_details),
        metadata: request.metadata.merge(
          "updates" => updates,
          "last_update_message_id" => @guest_message.id,
          "last_update_at" => Time.current.iso8601
        )
      )
      request
    end

    def create_request(category)
      @conversation.guest_requests.create!(
        account: @conversation.property.account,
        property: @conversation.property,
        guest: @conversation.guest,
        message: @guest_message,
        ai_decision_log: latest_ai_trace,
        guest_phone: @conversation.guest.phone_number,
        property_name: @conversation.property.display_name,
        property_address: @conversation.property.address,
        category: category,
        title: request_title(category),
        description: request_text,
        ai_summary: ai_summary,
        status: "pending",
        priority: priority_for(category),
        requires_owner_approval: requires_owner_approval?(category),
        structured_details: structured_details,
        source_channel: @guest_message.channel.presence || "whatsapp",
        metadata: {
          "source" => "ai_guest_request",
          "decision" => @decision.outcome,
          "proposed_action" => @decision.proposed_action,
          "detected_intents" => @decision.detected_intents,
          "evidence_ids" => @decision.evidence_ids,
          "approval_required" => requires_owner_approval?(category)
        }.compact
      )
    rescue ActiveRecord::RecordNotUnique
      GuestRequest.find_by!(message: @guest_message)
    end

    def latest_ai_trace
      AIDecisionLog.where(conversation: @conversation, message: @guest_message).order(created_at: :desc).first ||
        AIDecisionLog.where(conversation: @conversation, original_message: @guest_message).order(created_at: :desc).first
    end

    def request_title(category)
      "#{@conversation.guest.phone_number.to_s.delete_prefix("+")} · Pedido"
    end

    def action_title
      @decision.proposed_action.to_h.dig("payload", "title") ||
        @decision.proposed_action.to_h["title"]
    end

    def request_text
      @guest_message.body.to_s
        .delete_prefix(@conversation.property.whatsapp_reference)
        .gsub(@conversation.property.whatsapp_reference, "")
        .strip
        .presence || @guest_message.body.to_s
    end

    def ai_summary
      @decision.alert_description.presence ||
        @decision.escalation.to_h["summary_for_host"].presence ||
        @decision.intent_summary.presence ||
        @decision.proposed_action.to_h["details"].presence ||
        request_text
    end

    def priority_for(category)
      category.in?(%w[early_checkin late_checkout reservation_change]) ? "high" : "normal"
    end

    def requires_owner_approval?(category)
      category.in?(GuestRequest::APPROVAL_CATEGORIES) ||
        @decision.required_capabilities.include?("owner_approval") ||
        @decision.required_capabilities.include?("owner_attention") ||
        truthy?(@decision.proposed_action.to_h["requires_approval"]) ||
        @decision.escalation_required
    end

    def structured_details
      payload = @decision.proposed_action.to_h["payload"]
      payload.is_a?(Hash) ? payload.stringify_keys : {}
    end

    def inferred_update_field
      return "guest_clarification" if @decision.outcome == "ask_clarifying_question"
      return "owner_approval" if requires_owner_approval?(request_category)

      "details"
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end
  end
end
