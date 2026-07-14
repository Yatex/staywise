module CheckoutEvents
  class Creator
    def self.call(conversation:, decision:, guest_message:, owner_whatsapp_provider: Whatsapp::ProviderFactory.build)
      new(
        conversation: conversation,
        decision: decision,
        guest_message: guest_message,
        owner_whatsapp_provider: owner_whatsapp_provider
      ).call
    end

    def initialize(conversation:, decision:, guest_message:, owner_whatsapp_provider:)
      @conversation = conversation
      @decision = decision
      @guest_message = guest_message
      @owner_whatsapp_provider = owner_whatsapp_provider
    end

    def call
      return unless @decision.action == "check_out"

      created = false
      event = @conversation.with_lock do
        CheckoutEvent.find_by(account_id: account.id, reservation_key: reservation_key) || begin
          created = true
          CheckoutEvent.create!(
            account: @conversation.property.account,
            property: @conversation.property,
            guest: @conversation.guest,
            conversation: @conversation,
            source_message: @guest_message,
            provider_message_sid: provider_message_sid,
            reservation_key: reservation_key,
            guest_message_body: @guest_message.body,
            checked_out_at: @guest_message.created_at || Time.current
          )
        end
      end

      Whatsapp::OwnerEscalationNotifier.call(item: event, provider: @owner_whatsapp_provider) if created
      event
    rescue ActiveRecord::RecordNotUnique
      CheckoutEvent.find_by(account_id: account.id, reservation_key: reservation_key) ||
        CheckoutEvent.find_by(source_message_id: @guest_message.id) ||
        CheckoutEvent.find_by(provider_message_sid: provider_message_sid)
    end

    private

    def provider_message_sid
      @guest_message.metadata.to_h["MessageSid"].presence || @guest_message.metadata.to_h["SmsMessageSid"].presence
    end

    def reservation_key
      @reservation_key ||= if @conversation.guest.reservation_reference.present?
        "reference:#{@conversation.guest.reservation_reference}"
      elsif @conversation.guest.check_in_date.present? || @conversation.guest.checkout_date.present?
        ["property", @conversation.property_id, @conversation.guest.check_in_date, @conversation.guest.checkout_date].join(":")
      else
        "conversation:#{@conversation.id}"
      end
    end

    def account
      @conversation.property.account
    end
  end
end
