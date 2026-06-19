module Whatsapp
  class IncomingMessageHandler
    class MissingAccount < StandardError; end

    def initialize(params, provider: ProviderFactory.build)
      @params = params
      @provider = provider
    end

    def call
      parsed = InboundMessageParser.new(@params).call
      raise ArgumentError, "El mensaje entrante de WhatsApp está vacío." if parsed.body.blank?

      account = resolve_account
      property = resolve_property(account, parsed)
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

    def resolve_account
      Account.find_by(id: ENV["DEFAULT_ACCOUNT_ID"]) || Account.first || raise(MissingAccount)
    end

    def resolve_property(account, parsed)
      account.properties.find_by(id: parsed.property_id) ||
        account.guests.find_by(phone_number: parsed.from)&.property ||
        account.properties.active.first ||
        account.properties.first ||
        raise(ActiveRecord::RecordNotFound, "No hay una propiedad disponible para enrutar WhatsApp.")
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

      conversation.messages.create!(sender: "ai", channel: "whatsapp", body: decision.response_text, metadata: decision.to_h)
      @provider.send_message(to: guest.phone_number, body: decision.response_text)
    end
  end
end
