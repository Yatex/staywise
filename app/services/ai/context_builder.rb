module AI
  class ContextBuilder
    def initialize(conversation:, guest_message:)
      @conversation = conversation
      @guest_message = guest_message
      @property = conversation.property
      @guest = conversation.guest
    end

    def call
      registry = SourceRegistry.new(conversation: @conversation)
      authorization = ReservationAuthorization.new(guest: @guest, property: @property)

      {
        guest_message: @guest_message.body,
        guest_language: LanguageHelper.detect(@guest_message.body, fallback: @guest.language),
        owner_language: LanguageHelper.owner_language(@property.account),
        guest: guest_payload,
        property: property_payload,
        reservation: {
          status: authorization.reservation_status,
          sensitive_access_authorized: authorization.sensitive_access_authorized?
        },
        owner_instructions: owner_instructions_payload,
        conversation_history: conversation_history_payload,
        tool_endpoint: tool_endpoint_payload,
        safety_rules: safety_rules,
        tool_context: tool_endpoint_payload.present? ? nil : registry.tool_context
      }
    end

    private

    def guest_payload
      {
        language: LanguageHelper.detect(@guest_message.body, fallback: @guest.language)
      }
    end

    def property_payload
      @property.slice(:name)
    end

    def owner_instructions_payload
      account = @property.account
      account.slice(
        :ai_tone,
        :ai_goal,
        :ai_response_style,
        :ai_preferred_language,
        :ai_default_channel
      ).merge(ai_active: account.ai_active?)
    end

    def conversation_history_payload
      @conversation.messages.order(:created_at, :id).map do |message|
        message.slice(:sender, :body, :channel, :created_at)
      end
    end

    def tool_endpoint_payload
      base_url = ENV["AI_TOOLS_BASE_URL"].presence || ENV["APP_HOST"].presence
      return if base_url.blank?

      {
        base_url: base_url,
        decision_context_id: DecisionContext.issue(conversation: @conversation, guest_message: @guest_message)
      }
    end

    def safety_rules
      [
        "Return only structured JSON matching the decision contract.",
        "Always write response_text in guest_language. Owner-facing alert fields and suggested_owner_action must stay in owner_language.",
        "Use property_brain before factual replies and cite used_source_ids from returned source ids.",
        "Use sensitive_access_info for WiFi, passwords, keys, codes, lockboxes, and access instructions.",
        "Do not answer without evidence from a provided tool result.",
        "Use a warm complete sentence for direct facts; do not reply with only a raw value like a time or password.",
        "If the guest only greets, sends the default QR/link message, or has not asked a real property question, ask how you can help without creating an owner alert.",
        "If the guest question is ambiguous but likely refers to known property facts, ask one friendly clarifying question without creating an owner alert.",
        "For ambiguous time questions like 'what time can I go?' or 'a qué hora puedo ir?', ask whether they mean arrival/check-in or departure/checkout.",
        "Never approve early check-in, late checkout, refunds, discounts, compensation, booking changes, or access outside permitted hours.",
        "Only escalate when information is truly missing, the guest asks for an approval/exception, or a clarification still cannot resolve the request."
      ]
    end
  end
end
