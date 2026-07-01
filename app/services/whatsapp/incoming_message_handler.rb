module Whatsapp
  class IncomingMessageHandler
    MISSING_PROPERTY_CONTEXT_REPLY = "I need the property details before I can answer safely. Please scan the property QR code again or open the property link and send your message from there.".freeze

    def initialize(params, provider: ProviderFactory.build)
      @params = params
      @provider = provider
    end

    def call
      parsed = InboundMessageParser.new(@params).call
      raise ArgumentError, "El mensaje entrante de WhatsApp está vacío." if parsed.body.blank?

      property = resolve_property(parsed)
      return missing_property_context(parsed) if property.blank?

      account = property.account
      guest = resolve_guest(account, property, parsed)
      conversation = resolve_conversation(guest, property)
      guest_message = conversation.messages.create!(
        sender: "guest",
        channel: "whatsapp",
        body: parsed.body,
        metadata: parsed.metadata
      )

      unless account.ai_active? && property.ai_enabled?
        conversation.update!(ai_enabled: false)
        return { conversation: conversation, message: guest_message, decision: nil, alert: nil, replied: false }
      end

      decision = AI::DecisionService.call(conversation: conversation, guest_message: guest_message)
      alert = Alerts::Creator.call(conversation: conversation, decision: decision)
      replied = maybe_reply(conversation, guest, decision)
      conversation.update!(status: "escalated") if alert.present?

      { conversation: conversation, message: guest_message, decision: decision, alert: alert, replied: replied }
    end

    private

    def resolve_property(parsed)
      if parsed.property_token.present?
        property = Property.includes(:account).find_by(public_token: parsed.property_token)
        return property if property.present?
      end

      Guest.includes(:property).find_by(phone_number: parsed.from)&.property
    end

    def resolve_guest(account, property, parsed)
      account.guests.find_or_create_by!(phone_number: parsed.from) do |guest|
        guest.property = property
        guest.name = "Huésped de WhatsApp"
      end.tap do |guest|
        guest.update!(property: property) if guest.property.blank?
      end
    end

    def resolve_conversation(guest, property)
      guest.conversations.where(property: property).open.order(updated_at: :desc).first ||
        guest.conversations.create!(property: property, status: "active", ai_enabled: true)
    end

    def maybe_reply(conversation, guest, decision)
      return false unless conversation.ai_enabled?
      return false unless conversation.property.account.ai_automation_enabled?("send_whatsapp_replies")
      return false unless decision.should_reply
      return false if decision.response_text.blank?

      body = ai_response_body(conversation, decision)
      delivered = @provider.send_message(to: guest.phone_number, body: body)
      return false unless delivered

      conversation.messages.create!(sender: "ai", channel: "whatsapp", body: body, metadata: decision.to_h)
      true
    end

    def ai_response_body(conversation, decision)
      return decision.response_text if conversation.messages.where(sender: "ai").exists?

      AI::LanguageHelper.with_owner_disclosure(
        decision.response_text,
        text: conversation.messages.where(sender: "guest").order(created_at: :desc).pick(:body),
        fallback_language: conversation.guest.language
      )
    end

    def missing_property_context(parsed)
      replied = @provider.send_message(to: parsed.from, body: MISSING_PROPERTY_CONTEXT_REPLY)
      Rails.logger.info("[whatsapp-routing] missing_property_context from=#{parsed.from} replied=#{replied}")
      {
        conversation: nil,
        message: nil,
        decision: nil,
        alert: nil,
        replied: replied,
        error: "missing_property_context"
      }
    end
  end
end
