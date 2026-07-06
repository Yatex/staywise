module Whatsapp
  class IncomingMessageHandler
    MISSING_PROPERTY_CONTEXT_REPLY = "I need the property details before I can answer safely. Please scan the property QR code again or open the property link and send your message from there.".freeze
    ROUTING_INIT_MESSAGE_TYPE = "routing_init".freeze
    ROUTING_GREETING_MESSAGE_TYPE = "routing_greeting".freeze

    def initialize(params, provider: ProviderFactory.build)
      @params = params
      @provider = provider
    end

    def call
      parsed = InboundMessageParser.new(@params).call
      raise ArgumentError, "El mensaje entrante de WhatsApp está vacío." if parsed.body.blank?

      if OwnerInboundMessageHandler.owner_message?(parsed)
        return OwnerInboundMessageHandler.new(parsed, provider: @provider).call
      end

      property = resolve_property(parsed)
      return missing_property_context(parsed) if property.blank?

      account = property.account
      guest = resolve_guest(account, property, parsed)
      conversation = resolve_conversation(guest, property)
      guest_message = conversation.messages.create!(
        sender: "guest",
        channel: "whatsapp",
        body: parsed.body,
        metadata: guest_message_metadata(parsed, property)
      )

      if routing_init_message?(parsed, property)
        replied = maybe_reply_to_routing_init(conversation, guest, parsed)
        return { conversation: conversation, message: guest_message, decision: nil, alert: nil, replied: replied, routing_init: true }
      end

      unless account.ai_active? && property.ai_enabled?
        conversation.update!(ai_enabled: false)
        return { conversation: conversation, message: guest_message, decision: nil, alert: nil, replied: false }
      end

      decision = AI::DecisionService.call(conversation: conversation, guest_message: guest_message)
      alert = Alerts::Creator.call(conversation: conversation, decision: decision, owner_whatsapp_provider: @provider)
      replied = maybe_reply(conversation, guest, decision, alert: alert)
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

    def guest_message_metadata(parsed, property)
      metadata = parsed.metadata.to_h
      return metadata unless routing_init_message?(parsed, property)

      metadata.merge(
        "message_type" => ROUTING_INIT_MESSAGE_TYPE,
        "routing_init" => true,
        "property_token" => parsed.property_token,
        "handled_by" => "whatsapp_routing"
      )
    end

    def routing_init_message?(parsed, property)
      return false if parsed.property_token.blank?

      text = parsed.body.to_s.gsub(InboundMessageParser::PUBLIC_TOKEN_PATTERN, "")
      [property.display_name, property.name].compact_blank.uniq.each do |name|
        text = text.gsub(name.to_s, "")
      end

      text = text
        .downcase
        .gsub(/[[:punct:]¿?¡!]+/, " ")
        .squish

      return true if text.blank?

      normalized = text.gsub(/\b(hola|hello|hi|hey|buenas|buenos dias|buenos días|buenas tardes|buenas noches|tengo|una|un|consulta|sobre|del|de|la|el|para|por|favor|gracias)\b/i, " ").squish
      normalized.blank?
    end

    def maybe_reply_to_routing_init(conversation, guest, parsed)
      return false unless conversation.property.account.ai_automation_enabled?("send_whatsapp_replies")

      body = routing_greeting_for(conversation.property, parsed.body)
      delivery = @provider.send_message(to: guest.phone_number, body: body)
      delivered = delivery_success?(delivery)

      conversation.messages.create!(
        sender: "system",
        channel: "whatsapp",
        body: body,
        metadata: {
          "message_type" => ROUTING_GREETING_MESSAGE_TYPE,
          "handled_by" => "rails",
          "owner_disclosure" => true
        }.merge(delivery_metadata(delivery, delivered: delivered))
      )
      delivered
    end

    def routing_greeting_for(property, text)
      property_name = property.display_name

      case AI::LanguageHelper.detect(text, fallback: property.account.ai_preferred_language)
      when "es"
        "Hola, soy Ayla, la asistente de #{property_name}. ¿En qué puedo ayudarte?\n\nTené en cuenta que el dueño de la propiedad también puede leer este chat."
      else
        "Hi, I’m Ayla, the assistant for #{property_name}. How can I help you?\n\nPlease note that the property owner can also read this chat."
      end
    end

    def maybe_reply(conversation, guest, decision, alert:)
      return false unless conversation.ai_enabled?
      return false unless conversation.property.account.ai_automation_enabled?("send_whatsapp_replies")
      return false unless decision.should_reply
      return false if decision.response_text.blank?

      body = ai_response_body(conversation, decision, alert: alert)
      delivery = @provider.send_message(to: guest.phone_number, body: body)
      delivered = delivery_success?(delivery)

      conversation.messages.create!(
        sender: "ai",
        channel: "whatsapp",
        body: body,
        metadata: decision.to_h.merge(delivery_metadata(delivery, delivered: delivered))
      )
      delivered
    end

    def ai_response_body(conversation, decision, alert:)
      response_text = safe_response_text_for(decision, alert: alert, conversation: conversation)
      return response_text if owner_disclosure_already_sent?(conversation)

      AI::LanguageHelper.with_owner_disclosure(
        response_text,
        text: conversation.messages.where(sender: "guest").order(created_at: :desc).pick(:body),
        fallback_language: conversation.guest.language
      )
    end

    def owner_disclosure_already_sent?(conversation)
      return true if conversation.messages.where(sender: "ai").exists?

      conversation.messages.any? { |message| ActiveModel::Type::Boolean.new.cast(message.metadata.to_h["owner_disclosure"]) }
    end

    def safe_response_text_for(decision, alert:, conversation:)
      return decision.response_text unless decision.escalation_required && alert.blank?

      AI::LanguageHelper.not_confirmed_no_alert_reply_for(
        conversation.messages.where(sender: "guest").order(created_at: :desc).pick(:body),
        fallback_language: conversation.guest.language
      )
    end

    def missing_property_context(parsed)
      delivery = @provider.send_message(to: parsed.from, body: MISSING_PROPERTY_CONTEXT_REPLY)
      replied = delivery_success?(delivery)
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

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_metadata(delivery, delivered:)
      unless delivered
        return {
          "delivery_status" => "failed",
          "delivery_error" => delivery_error(delivery),
          "delivery_status_updated_at" => Time.current.iso8601
        }.compact
      end

      return {
        "delivery_status" => "sent",
        "delivery_status_updated_at" => Time.current.iso8601
      } unless delivery.respond_to?(:provider_message_id)

      {
        "provider_message_id" => delivery.provider_message_id,
        "provider_status" => delivery.provider_status,
        "delivery_status" => delivery.provider_status.presence || "accepted_by_provider",
        "delivery_status_updated_at" => Time.current.iso8601
      }.compact
    end

    def delivery_error(delivery)
      if delivery.respond_to?(:error) && delivery.error.present?
        delivery.error
      else
        "whatsapp_delivery_failed"
      end
    end
  end
end
