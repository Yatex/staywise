module Whatsapp
  # The public WhatsApp number is no longer a guest support channel. Copilot
  # work is created only by authenticated users through Copilot controllers.
  # Keeping this boundary free of providers, conversations and AI services is
  # intentional: an inbound webhook cannot produce an outbound message.
  class CopilotInboundRouter
    def initialize(params)
      @params = params
    end

    def call
      parsed = InboundMessageParser.new(@params).call
      role = host_phone?(parsed.from) ? "host" : "external"

      Rails.logger.info(
        "[whatsapp-inbound] retired_channel role=#{role} " \
        "from=#{parsed.from} message_sid=#{message_sid(parsed)}"
      )

      {
        conversation: nil,
        replied: false,
        ignored: true,
        channel: role,
        error: role == "host" ? "host_whatsapp_copilot_not_enabled" : "guest_whatsapp_channel_retired"
      }
    end

    private

    def host_phone?(phone_number)
      phone = HostActor.normalize(phone_number)
      Account.where(owner_whatsapp_number: phone).exists? || CoHost.where(whatsapp_number: phone).exists?
    end

    def message_sid(parsed)
      parsed.metadata.to_h["MessageSid"] || parsed.metadata.to_h["SmsMessageSid"]
    end
  end
end
