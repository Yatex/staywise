module Whatsapp
  # The public WhatsApp number accepts verified hosts as a Copilot interface.
  # External senders remain side-effect free and are never treated as guests.
  class CopilotInboundRouter
    def initialize(params, provider: nil, client: nil)
      @params = params
      @provider = provider
      @client = client
    end

    def call
      parsed = InboundMessageParser.new(@params).call
      identity = HostCopilotIdentity.resolve(parsed.from)
      return ignored_external(parsed) unless identity

      Rails.logger.info(
        "[whatsapp-inbound] host_copilot role=#{identity.role} account_id=#{identity.account.id} " \
        "from=#{parsed.from} message_sid=#{message_sid(parsed)}"
      )
      options = { parsed: parsed, identity: identity }
      options[:provider] = @provider if @provider
      options[:client] = @client if @client
      HostCopilotHandler.new(**options).call
    rescue ActiveRecord::RecordNotFound => error
      Rails.logger.warn("[whatsapp-inbound] ambiguous_host_identity #{error.message}")
      { conversation: nil, replied: false, ignored: true, channel: "external", error: "ambiguous_host_identity" }
    end

    private

    def ignored_external(parsed)
      Rails.logger.info(
        "[whatsapp-inbound] retired_guest_channel from=#{parsed.from} message_sid=#{message_sid(parsed)}"
      )
      {
        conversation: nil,
        replied: false,
        ignored: true,
        channel: "external",
        error: "guest_whatsapp_channel_retired"
      }
    end

    def message_sid(parsed)
      parsed.metadata.to_h["MessageSid"] || parsed.metadata.to_h["SmsMessageSid"]
    end
  end
end
