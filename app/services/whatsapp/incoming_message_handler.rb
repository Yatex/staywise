module Whatsapp
  class IncomingMessageHandler
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
      conversation = resolve_conversation(guest, property, parsed)
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
      report_missing_alert(conversation: conversation, decision: decision) if decision.escalation_required && alert.blank?
      replied = maybe_reply(conversation, guest, decision, alert: alert)
      conversation.update!(status: "escalated") if alert.present?
      finalize_ai_trace(guest_message: guest_message, decision: decision, alert: alert, replied: replied)

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
        guest.update!(property: property) if guest.property.blank? || parsed.property_token.present?
      end
    end

    def resolve_conversation(guest, property, parsed)
      if parsed.property_token.present?
        conversation = guest.conversations.open.order(updated_at: :desc).first
        if conversation.present?
          relink_conversation!(conversation, property, parsed)
          return conversation
        end

        @routing_audit = {
          "token_detected" => true,
          "relinked" => false,
          "previous_property_id" => nil,
          "new_property_id" => property.id
        }
        Rails.logger.info("[whatsapp-property-routing] #{@routing_audit.to_json}")
      end

      guest.conversations.where(property: property).open.order(updated_at: :desc).first ||
        guest.conversations.create!(property: property, status: "active", ai_enabled: true)
    end

    def relink_conversation!(conversation, property, parsed)
      previous_property_id = conversation.property_id
      relinked = previous_property_id != property.id
      if relinked
        conversation.update!(property: property, ai_enabled: property.ai_enabled?)
        conversation.association(:property).reset
      end
      @routing_audit = {
        "token_detected" => parsed.property_token.present?,
        "relinked" => relinked,
        "previous_property_id" => previous_property_id,
        "new_property_id" => property.id
      }

      Rails.logger.info("[whatsapp-property-routing] #{@routing_audit.to_json}")
    end

    def guest_message_metadata(parsed, property)
      metadata = parsed.metadata.to_h
      metadata = metadata.merge(@routing_audit.to_h) if @routing_audit.present?
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
      message = conversation.messages.create!(
        sender: "system",
        channel: "whatsapp",
        body: body,
        metadata: {
          "message_type" => ROUTING_GREETING_MESSAGE_TYPE,
          "handled_by" => "rails",
          "delivery_status" => "pending",
          "delivery_status_updated_at" => Time.current.iso8601
        }
      )

      deliver_persisted_message(message, to: guest.phone_number, body: body)
    end

    def routing_greeting_for(property, text)
      AI::LanguageHelper.multilingual_welcome
    end

    def maybe_reply(conversation, guest, decision, alert:)
      return false unless conversation.ai_enabled?
      return false unless conversation.property.account.ai_automation_enabled?("send_whatsapp_replies")
      return false unless decision.should_reply
      return false if decision.response_text.blank?

      body = ai_response_body(conversation, decision, alert: alert)
      return false if body.blank?

      message = conversation.messages.create!(
        sender: "ai",
        channel: "whatsapp",
        body: body,
        metadata: decision.to_h.merge(
          "delivery_status" => "pending",
          "delivery_status_updated_at" => Time.current.iso8601
        )
      )

      deliver_persisted_message(message, to: guest.phone_number, body: body)
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

      decision.safe_fallback_response
    end

    def missing_property_context(parsed)
      delivery = @provider.send_message(to: parsed.from, body: missing_property_context_reply(parsed))
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

    def missing_property_context_reply(parsed)
      case AI::LanguageHelper.detect(parsed.body, fallback: "es")
      when "en"
        "I need the property details before I can answer safely. Please scan the property QR code again or open the property link and send your message from there."
      else
        "Necesito los datos de la propiedad para responder con seguridad. Escaneá de nuevo el QR de la propiedad o abrí el link de la propiedad y enviá tu consulta desde ahí."
      end
    end

    def report_missing_alert(conversation:, decision:)
      ErrorReporter.report(
        source: "ai_service",
        severity: "warning",
        account: conversation.property.account,
        property: conversation.property,
        message: "AI requested escalation but Rails did not create an alert",
        context: {
          conversation_id: conversation.id,
          guest_id: conversation.guest_id,
          decision: decision.outcome,
          alert_type: decision.alert_type,
          create_alerts_enabled: conversation.property.account.ai_automation_enabled?("create_alerts"),
          alert_type_enabled: conversation.property.account.ai_escalates?(decision.alert_type)
        }
      )
    end

    def finalize_ai_trace(guest_message:, decision:, alert:, replied:)
      log = AIDecisionLog.where(message: guest_message).order(created_at: :desc).first
      return unless log

      alert.update!(ai_decision_log: log) if alert.present? && alert.ai_decision_log.blank?

      outbound_message = log.conversation&.messages&.where(sender: "ai")&.where("created_at >= ?", guest_message.created_at)&.order(created_at: :desc)&.first
      delivery_status = if outbound_message
        outbound_message.metadata["delivery_status"].presence || outbound_message.metadata["provider_status"].presence || (replied ? "sent" : "failed")
      elsif decision.should_reply
        "outbound_message_not_persisted"
      else
        "not_applicable"
      end

      alert_payload = if alert.present?
        {
          created: true,
          id: alert.id,
          type: alert.alert_type,
          status: alert.status,
          visible_for_owner: Alert.joins(:property).where(properties: { account_id: alert.property.account_id }).open.where(id: alert.id).exists?
        }
      else
        {
          created: false,
          expected: decision.escalation_required,
          reason: decision.escalation_required ? "rails_did_not_create_alert" : nil
        }.compact
      end

      whatsapp_payload = {
        sent: replied,
        delivery_status: delivery_status,
        provider_status: outbound_message&.metadata&.dig("provider_status"),
        provider_error: outbound_message&.metadata&.dig("delivery_error")
      }

      log.update!(
        provider_delivery_status: delivery_status,
        payload: log.payload.merge(
          "alert" => alert_payload,
          "whatsapp_delivery" => whatsapp_payload
        )
      )
    rescue StandardError => error
      Rails.logger.warn("[ai-audit] finalize_failed #{error.class}: #{error.message}")
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def deliver_persisted_message(message, to:, body:)
      delivery = @provider.send_message(to: to, body: body)
      delivered = delivery_success?(delivery)

      message.update!(
        metadata: message.metadata.merge(delivery_metadata(delivery, delivered: delivered))
      )
      delivered
    rescue StandardError => error
      message.update!(
        metadata: message.metadata.merge(
          "delivery_status" => "failed",
          "delivery_error" => error.message,
          "delivery_status_updated_at" => Time.current.iso8601
        )
      )
      Rails.logger.warn("[whatsapp-delivery] failed_after_persist message_id=#{message.id} error=#{error.class}: #{error.message}")
      false
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
