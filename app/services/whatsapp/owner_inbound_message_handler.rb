module Whatsapp
  class OwnerInboundMessageHandler
    INBOX_COMMAND = /\Aalertas\z/i
    NUMERIC_SELECTION = /\A(\d{1,2})\z/

    def self.owner_message?(parsed)
      Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: parsed.from).exists?
    end

    def initialize(parsed, provider: ProviderFactory.build)
      @parsed = parsed
      @provider = provider
      @owner_whatsapp_number = parsed.from
    end

    def call
      body = @parsed.body.to_s.strip

      return list_alerts if inbox_command?(body)
      return owner_assistant_response(body) if OwnerAssistant.query?(body)
      return select_alert(body.to_i) if numeric_selection?(body)

      if (session = selected_session)
        return answer_alert(session, body)
      end

      send_owner_message("No hay una alerta seleccionada. Respondé ALERTAS para ver las alertas abiertas y elegí una por número.")
      { owner_message: true, handled: true, session: nil, replied: true }
    end

    private

    def inbox_command?(body)
      body.match?(INBOX_COMMAND)
    end

    def numeric_selection?(body)
      body.match?(NUMERIC_SELECTION)
    end

    def owner_assistant_response(body)
      replied = OwnerAssistant.call(owner_whatsapp_number: @owner_whatsapp_number, body: body, provider: @provider)

      { owner_message: true, handled: true, session: selected_session, replied: replied, owner_assistant: true }
    end

    def list_alerts
      sessions = open_sessions
      if sessions.blank?
        send_owner_message("No tenés alertas abiertas en Ayla.")
        return { owner_message: true, handled: true, session: nil, replied: true, inbox: true }
      end

      listed_at = Time.current
      lines = ["Alertas abiertas:"]
      sessions.each.with_index(1) do |session, index|
        alert = session.alert
        session.update!(
          metadata: session.metadata.merge(
            "last_listed_position" => index,
            "last_listed_at" => listed_at.iso8601
          )
        )
        session.append_event!("owner_alert_listed", position: index, alert_id: alert.id)

        lines << "#{index}. #{guest_label(alert)} · #{alert.property.display_name}"
        lines << "   #{alert_summary(alert)} · #{age_label(alert.created_at)}"
      end
      lines << ""
      lines << "Respondé con el número de la alerta que querés ver."

      send_owner_message(lines.join("\n"))
      { owner_message: true, handled: true, session: nil, replied: true, inbox: true }
    end

    def select_alert(position)
      session = session_for_position(position)
      unless session
        send_owner_message("No encontré esa alerta. Respondé ALERTAS para ver la lista actualizada.")
        return { owner_message: true, handled: true, session: nil, replied: true, inbox: true }
      end

      selected_session&.update!(state: "queued")
      session.alert.update!(status: "in_progress") if session.alert.status == "open"
      session.update!(state: "awaiting_answer", last_owner_message_at: Time.current)
      session.append_event!("owner_alert_selected", position: position, alert_id: session.alert_id)

      delivery = send_owner_message(alert_detail_text(session.alert))
      { owner_message: true, handled: true, session: session, replied: delivery, selected: true }
    end

    def answer_alert(session, answer)
      if answer.blank?
        send_owner_message("Escribí la respuesta que querés enviarle al huésped, o respondé ALERTAS para elegir otra alerta.")
        return { owner_message: true, handled: true, session: session, replied: true }
      end

      alert = session.alert
      conversation = alert.conversation
      unless conversation&.guest&.phone_number.present?
        session.append_event!("owner_guest_reply_failed", error: "missing_guest_phone", alert_id: alert.id)
        send_owner_message("No pude enviar la respuesta porque esta alerta no tiene un huésped de WhatsApp asociado.")
        return { owner_message: true, handled: true, session: session, replied: false }
      end

      guest_language = conversation.guest.language.presence || AI::LanguageHelper.owner_language(conversation.property.account)
      guest_answer = translate_owner_answer(answer, conversation, guest_language)
      owner_message = conversation.messages.create!(
        sender: "owner",
        channel: "whatsapp",
        body: guest_answer,
        metadata: {
          sent_via: "owner_whatsapp_alert_inbox",
          owner_phone_number: @owner_whatsapp_number,
          alert_id: alert.id,
          original_owner_body: answer,
          translated_to: guest_language,
          delivery_status: "pending",
          delivery_status_updated_at: Time.current.iso8601
        }.compact
      )
      delivery = @provider.send_message(to: conversation.guest.phone_number, body: guest_answer)
      delivered = delivery_success?(delivery)
      owner_message.update!(metadata: owner_message.metadata.merge(delivery_metadata(delivery, delivered: delivered)).compact)

      unless delivered
        session.append_event!("owner_guest_reply_failed", error: delivery_error(delivery), alert_id: alert.id)
        send_owner_message("No pude enviar esa respuesta al huésped por WhatsApp. Quedó auditada en la conversación; probá de nuevo en unos minutos.")
        return { owner_message: true, handled: true, session: session, replied: false }
      end

      KnowledgeSuggestions::OwnerAnswerFaqCreator.call(alert: alert, owner_answer: answer, owner_message: owner_message)
      alert.update!(status: "resolved")
      session.update!(state: "resolved", resolved_at: Time.current, last_owner_message_at: Time.current)
      session.append_event!("owner_guest_reply_sent", alert_id: alert.id, conversation_id: conversation.id)
      send_owner_message("Listo, le envié tu respuesta al huésped y cerré la alerta.")

      { owner_message: true, handled: true, session: session, replied: true }
    end

    def selected_session
      @selected_session ||= owner_sessions.where(state: "awaiting_answer").order(updated_at: :desc).first
    end

    def session_for_position(position)
      return if position <= 0

      recent_cutoff = 30.minutes.ago.iso8601
      owner_sessions
        .includes(alert: [:property, :guest, :conversation])
        .where.not(state: %w[resolved failed])
        .find do |session|
          session.metadata["last_listed_position"].to_i == position &&
            session.metadata["last_listed_at"].to_s >= recent_cutoff &&
            session.alert.status.in?(%w[open in_progress])
        end || open_sessions[position - 1]
    end

    def open_sessions
      @open_sessions ||= begin
        owner_accounts.flat_map do |account|
          Alert.joins(:property)
            .where(properties: { account_id: account.id })
            .open
            .includes(:property, :guest, :conversation)
            .order(created_at: :asc)
            .map { |alert| account.owner_whatsapp_sessions.find_or_create_by!(alert: alert) }
        end.sort_by { |session| session.alert.created_at }
      end
    end

    def owner_sessions
      OwnerWhatsappSession.joins(:account).where(accounts: {
        owner_whatsapp_escalations_enabled: true,
        owner_whatsapp_number: @owner_whatsapp_number
      })
    end

    def owner_accounts
      @owner_accounts ||= Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: @owner_whatsapp_number).to_a
    end

    def alert_detail_text(alert)
      [
        "Alerta ##{alert.id}",
        "Propiedad: #{alert.property.display_name}",
        "Huésped: #{guest_label(alert)}",
        "Tipo: #{ApplicationController.helpers.enum_label(alert.alert_type)}",
        "Resumen: #{alert_summary(alert)}",
        "",
        "Último mensaje del huésped:",
        last_guest_message(alert),
        "",
        "Contexto / sugerencia:",
        alert.ai_suggested_action.presence || "Revisá la conversación y respondé con el texto que querés enviarle al huésped.",
        "",
        "Respondé ahora con el mensaje que querés enviarle al huésped. Si querés ver otra alerta, respondé ALERTAS."
      ].join("\n")
    end

    def guest_label(alert)
      alert.guest&.phone_number.to_s.delete_prefix("+").presence ||
        alert.guest&.display_name ||
        "Huésped de WhatsApp"
    end

    def alert_summary(alert)
      alert.description.presence || alert.title
    end

    def last_guest_message(alert)
      alert.conversation&.messages&.where(sender: "guest")&.order(created_at: :desc)&.first&.body.presence ||
        alert.description.presence ||
        "Sin mensaje de huésped asociado."
    end

    def age_label(time)
      seconds = (Time.current - time).to_i
      if seconds < 60
        "hace menos de 1 min"
      elsif seconds < 3600
        "hace #{seconds / 60} min"
      elsif seconds < 86_400
        "hace #{seconds / 3600} h"
      else
        "hace #{seconds / 86_400} d"
      end
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
