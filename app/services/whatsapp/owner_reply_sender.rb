module Whatsapp
  class OwnerReplySender
    Result = Struct.new(:success?, :message, :error, keyword_init: true)

    def self.call(conversation:, user:, body:, provider: ProviderFactory.build)
      new(conversation: conversation, user: user, body: body, provider: provider).call
    end

    def initialize(conversation:, user:, body:, provider:)
      @conversation = conversation
      @user = user
      @body = body.to_s.strip
      @provider = provider
    end

    def call
      return failure("Escribí un mensaje para enviar.") if @body.blank?
      return failure("El huésped no tiene teléfono de WhatsApp configurado.") if guest_phone.blank?

      delivered = @provider.send_message(to: guest_phone, body: @body)
      return failure("No se pudo enviar el mensaje por WhatsApp. Revisá la configuración del proveedor.") unless delivered

      message = @conversation.messages.create!(
        sender: "owner",
        channel: "whatsapp",
        body: @body,
        metadata: {
          sent_by_user_id: @user.id,
          sent_by_user_name: @user.name,
          sent_via: "ayla_dashboard"
        }
      )

      Result.new(success?: true, message: message, error: nil)
    end

    private

    def guest_phone
      @conversation.guest&.phone_number
    end

    def failure(error)
      Result.new(success?: false, message: nil, error: error)
    end
  end
end
