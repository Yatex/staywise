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

      guest_body = translated_body
      message = @conversation.messages.create!(
        sender: "owner",
        channel: "whatsapp",
        body: guest_body,
        metadata: {
          sent_by_user_id: @user.id,
          sent_by_user_name: @user.name,
          sent_via: "ayla_dashboard",
          original_owner_body: @body,
          translated_to: guest_language,
          delivery_status: "pending",
          delivery_status_updated_at: Time.current.iso8601
        }.compact
      )
      delivery = @provider.send_message(to: guest_phone, body: guest_body)
      delivered = delivery_success?(delivery)
      message.update!(metadata: message.metadata.merge(delivery_metadata(delivery, delivered: delivered)).compact)

      return failure(delivery_error(delivery), message: message) unless delivered

      create_pending_knowledge_suggestion(message)
      Result.new(success?: true, message: message, error: nil)
    end

    private

    def create_pending_knowledge_suggestion(message)
      alert = @conversation.alerts.open.order(created_at: :desc).first
      return if alert.blank?

      KnowledgeSuggestions::OwnerAnswerFaqCreator.call(
        alert: alert,
        owner_answer: @body,
        owner_message: message
      )
    end

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

    def delivery_metadata(delivery, delivered:)
      unless delivered
        return {
          delivery_status: "failed",
          delivery_error: delivery_error(delivery),
          delivery_status_updated_at: Time.current.iso8601
        }.compact
      end

      return {
        delivery_status: "sent",
        delivery_status_updated_at: Time.current.iso8601
      } unless delivery.respond_to?(:provider_message_id)

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

    def translated_body
      AI::Translator.call(
        text: @body,
        source_language: AI::LanguageHelper.owner_language(@conversation.property.account),
        target_language: guest_language,
        context: "Translate the host's dashboard reply before sending it to the guest on WhatsApp."
      )
    end

    def guest_language
      @guest_language ||= @conversation.guest.language.presence ||
        AI::LanguageHelper.detect(@conversation.messages.where(sender: "guest").order(created_at: :desc).first&.body)
    end

    def failure(error, message: nil)
      Result.new(success?: false, message: message, error: error)
    end
  end
end
