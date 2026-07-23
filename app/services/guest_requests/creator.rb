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
      return unless @decision.owner_task_kind.in?(OwnerTask::KINDS)
      duplicate = duplicate_request
      return duplicate if duplicate

      category = @decision.owner_task_kind == "inquiry" ? "other" : request_category
      return unless category

      if (request = existing_request)
        update_request!(request)
      else
        result = create_request(category)
        notify_owner(result)
        result
      end
    end

    private

    def notify_owner(request)
      return unless request&.persisted?
      return unless @conversation.property.account.ai_automation_enabled?("send_owner_whatsapp_escalations")

      Whatsapp::OwnerEscalationNotifier.call(item: request)
    end

    def request_category
      action_type = @decision.proposed_action.to_h["type"].to_s
      return REQUEST_ACTION_TYPES[action_type] if REQUEST_ACTION_TYPES.key?(action_type)

      categories = detected_intents.filter_map do |intent|
        INTENT_CATEGORIES[intent["type"].to_s]
      end

      categories.find { |category| category != "other" } || categories.first || "other"
    end

    def detected_intents
      @decision.detected_intents.map(&:to_h).map(&:stringify_keys)
    end

    def existing_request
      return if @decision.owner_task_id.blank?

      @conversation.owner_tasks.open.find_by(
        id: @decision.owner_task_id,
        account: @conversation.property.account,
        property: @conversation.property,
        guest: @conversation.guest,
        kind: @decision.owner_task_kind
      )
    end

    def duplicate_request
      @duplicate_request ||= @conversation.owner_tasks.find_by(
        "metadata ->> 'source_guest_message_id' = ?",
        @guest_message.id.to_s
      )
      return @duplicate_request if @duplicate_request

      if (trace = latest_ai_trace)
        @duplicate_request = @conversation.owner_tasks.find_by(ai_decision_log: trace)
      end
    end

    def update_request!(request)
      request.with_lock do
        request.update!(
          title: @decision.title,
          category: request_category,
          ai_decision_log: latest_ai_trace || request.ai_decision_log,
          metadata: request.metadata.except(
            "updates",
            "last_update_message_id",
            "awaiting_guest_clarification",
            "detected_intents",
            "proposed_action",
            "evidence_ids"
          ).merge(
            "last_activity_at" => Time.current.iso8601,
            "has_new_activity" => true
          )
        )
      end
      request
    end

    def create_request(category)
      @conversation.owner_tasks.create!(
        account: @conversation.property.account,
        kind: @decision.owner_task_kind,
        property: @conversation.property,
        guest: @conversation.guest,
        message: nil,
        ai_decision_log: latest_ai_trace,
        guest_phone: @conversation.guest.phone_number,
        property_name: @conversation.property.display_name,
        property_address: @conversation.property.address,
        category: category,
        title: @decision.title,
        description: nil,
        ai_summary: nil,
        status: "open",
        priority: "normal",
        requires_owner_approval: requires_owner_approval?(category),
        structured_details: {},
        source_channel: @guest_message.channel.presence || "whatsapp",
        metadata: {
          "source" => "ai_guest_request",
          "source_guest_message_id" => @guest_message.id,
          "decision" => @decision.outcome,
          "approval_required" => requires_owner_approval?(category),
          "last_activity_at" => Time.current.iso8601,
          "has_new_activity" => false
        }.compact
      )
    rescue ActiveRecord::RecordNotUnique
      @conversation.owner_tasks.find_by!(
        "metadata ->> 'source_guest_message_id' = ?",
        @guest_message.id.to_s
      )
    end

    def latest_ai_trace
      AIDecisionLog.where(conversation: @conversation, message: @guest_message).order(created_at: :desc).first ||
        AIDecisionLog.where(conversation: @conversation, original_message: @guest_message).order(created_at: :desc).first
    end

    def requires_owner_approval?(category)
      return false if @decision.owner_task_kind == "inquiry"

      category.in?(GuestRequest::APPROVAL_CATEGORIES) ||
        @decision.required_capabilities.include?("owner_approval") ||
        @decision.required_capabilities.include?("owner_attention") ||
        truthy?(@decision.proposed_action.to_h["requires_approval"]) ||
        @decision.escalation_required
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end
  end
end
