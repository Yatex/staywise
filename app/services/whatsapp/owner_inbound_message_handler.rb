module Whatsapp
  class OwnerInboundMessageHandler
    COMMAND_HOLD = /\A(hold|pausar|pausa|dejar en espera|en espera|saltar|skip|next|siguiente)\z/i
    COMMAND_OK = /\A(ok|dale|si|sí|ver|detalle|ver detalle|ver_detalle|ver consulta|ver_consulta|details?|view details?|view_details?|responder|responder ahora)\z/i

    def self.owner_message?(parsed)
      Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: parsed.from).exists?
    end

    def initialize(parsed, provider: ProviderFactory.build)
      @parsed = parsed
      @provider = provider
      @owner_whatsapp_number = parsed.from
    end

    def call
      session = active_session
      return no_active_session unless session

      body = @parsed.body.to_s.strip
      return hold_session(session) if body.match?(COMMAND_HOLD)
      return send_alert_detail(session) if session.state == "awaiting_ack" || body.match?(COMMAND_OK)

      answer_alert(session, body)
    end

    private

    def active_session
      OwnerWhatsappSession.joins(:account)
        .where(accounts: { owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: @owner_whatsapp_number })
        .active
        .includes(alert: [:property, :guest, :conversation])
        .order(:updated_at)
        .first
    end

    def no_active_session
      next_result = Whatsapp::OwnerEscalationNotifier.drain_queue_for_owner(owner_whatsapp_number: @owner_whatsapp_number, provider: @provider)
      if next_result&.sent?
        send_owner_message("No había una consulta activa. Te envié la siguiente consulta pendiente.")
      else
        send_owner_message("No tenés consultas activas de Ayla en este momento.")
      end

      { owner_message: true, handled: true, session: nil, replied: true }
    end

    def hold_session(session)
      session.update!(state: "on_hold", last_owner_message_at: Time.current)
      session.alert.update!(status: "open") if session.alert.status == "in_progress"
      next_result = Whatsapp::OwnerEscalationNotifier.drain_queue_for_owner(owner_whatsapp_number: @owner_whatsapp_number, provider: @provider, except_session: session)

      message = if next_result&.sent?
        "Dejé esa consulta en espera y te envié la siguiente."
      else
        "Dejé esa consulta en espera. No hay otras consultas pendientes ahora."
      end
      send_owner_message(message)

      { owner_message: true, handled: true, session: session, replied: true }
    end

    def send_alert_detail(session)
      alert = session.alert
      guest_question = guest_question_for(alert)
      text = [
        "Consulta en #{alert.property.display_name}:",
        guest_question,
        "",
        "Respondé con el mensaje que querés enviarle al huésped. Si no sabés todavía, respondé HOLD."
      ].join("\n")

      delivery = send_owner_message(text)
      session.update!(state: "awaiting_answer", last_owner_message_at: Time.current) if delivery

      { owner_message: true, handled: true, session: session, replied: delivery }
    end

    def answer_alert(session, answer)
      return send_alert_detail(session) if answer.blank?

      alert = session.alert
      conversation = alert.conversation
      guest_language = conversation.guest.language.presence || AI::LanguageHelper.detect(conversation.messages.where(sender: "guest").order(created_at: :desc).first&.body)
      guest_answer = translate_owner_answer(answer, conversation, guest_language)
      delivery = @provider.send_message(to: conversation.guest.phone_number, body: guest_answer)
      unless delivery_success?(delivery)
        send_owner_message("No pude enviar esa respuesta al huésped por WhatsApp. Probá de nuevo en unos minutos.")
        return { owner_message: true, handled: true, session: session, replied: false }
      end

      conversation.messages.create!(
        sender: "owner",
        channel: "whatsapp",
        body: guest_answer,
        metadata: {
          sent_via: "owner_whatsapp_escalation",
          owner_phone_number: @owner_whatsapp_number,
          alert_id: alert.id,
          original_owner_body: answer,
          translated_to: guest_language
        }.merge(delivery_metadata(delivery)).compact
      )

      create_reusable_faq!(alert, answer)
      alert.update!(status: "resolved")
      session.update!(state: "resolved", resolved_at: Time.current, last_owner_message_at: Time.current)
      send_owner_message("Listo, le envié tu respuesta al huésped y guardé esta respuesta para futuras preguntas de esa propiedad.")
      Whatsapp::OwnerEscalationNotifier.drain_queue_for_owner(owner_whatsapp_number: @owner_whatsapp_number, provider: @provider)

      { owner_message: true, handled: true, session: session, replied: true }
    end

    def guest_question_for(alert)
      alert.description.presence ||
        alert.conversation&.messages&.where(sender: "guest")&.order(created_at: :desc)&.first&.body ||
        "El huésped hizo una consulta que Ayla no pudo responder."
    end

    def create_reusable_faq!(alert, answer)
      question = guest_question_for(alert).to_s.strip
      return if question.blank?
      return if alert.property.faqs.where("lower(question) = ?", question.downcase).exists?

      alert.property.faqs.create!(
        question: question,
        answer: answer,
        category: alert.alert_type.presence || "owner_answer",
        active: true
      )
    end

    def translate_owner_answer(answer, conversation, guest_language)
      AI::Translator.call(
        text: answer,
        source_language: AI::LanguageHelper.owner_language(conversation.property.account),
        target_language: guest_language,
        context: "Translate the host's answer before sending it to the guest on WhatsApp."
      )
    end

    def send_owner_message(body)
      delivery = @provider.send_message(to: @owner_whatsapp_number, body: body)
      delivery_success?(delivery)
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
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
  end
end
