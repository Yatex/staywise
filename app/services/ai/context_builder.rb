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
        safety_rules: safety_rules,
        tool_context: registry.tool_context
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
      @conversation.messages.order(created_at: :desc).limit(4).reverse.map do |message|
        message.slice(:sender, :body, :channel, :created_at)
      end
    end

    def safety_rules
      [
        "Return only structured JSON matching the decision contract.",
        "Always write response_text in guest_language. Owner-facing alert fields and suggested_owner_action must stay in owner_language.",
        "Do not answer without evidence from a provided tool result.",
        "Use a warm complete sentence for direct facts; do not reply with only a raw value like a time or password.",
        "If the guest only greets, sends the default QR/link message, or has not asked a real property question, ask how you can help without creating an owner alert.",
        "Never approve early check-in, late checkout, refunds, discounts, compensation, booking changes, or access outside permitted hours.",
        "If evidence is missing or approval is needed, escalate with a concise acknowledgement."
      ]
    end
  end
end
