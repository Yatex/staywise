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
      return failure("WhatsApp no está conectado. Configurá Twilio antes de responder desde Ayla.") if null_provider?

      delivery = @provider.send_message(to: guest_phone, body: @body)
      return failure(delivery_error(delivery)) unless delivery_success?(delivery)

      message = @conversation.messages.create!(
        sender: "owner",
        channel: "whatsapp",
        body: @body,
        metadata: {
          sent_by_user_id: @user.id,
          sent_by_user_name: @user.name,
          sent_via: "ayla_dashboard"
        }.merge(
          delivery_metadata(delivery)
        ).compact
      )

      Result.new(success?: true, message: message, error: nil)
    end

    private

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_error(delivery)
      if delivery.respond_to?(:error) && delivery.error.present?
        delivery.error
      else
        "No se pudo enviar el mensaje por WhatsApp. Revisá la configuración del proveedor."
      end
    end

    def delivery_metadata(delivery)
      return {} unless delivery.respond_to?(:provider_message_id)

      {
        provider_message_id: delivery.provider_message_id,
        provider_status: delivery.provider_status,
        delivery_status: delivery.provider_status.presence || "accepted_by_provider",
        delivery_status_updated_at: Time.current.iso8601
      }
    end

    def null_provider?
      @provider.is_a?(Whatsapp::Providers::NullProvider)
    end

    def guest_phone
      @conversation.guest&.phone_number
    end

    def failure(error)
      Result.new(success?: false, message: nil, error: error)
    end
  end
end
