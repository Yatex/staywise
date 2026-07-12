module Whatsapp
  class OwnerInboundMessageHandler
    CATEGORIES = %w[pedidos consultas alertas].freeze
    EXIT_COMMAND = /\Asalir\z/i
    SKIP_COMMAND = /\A(?:siguiente|omitir)\z/i
    REMEMBER_COMMAND = /\Arecordar\z/i
    FORGET_COMMAND = /\Ano_recordar\z/i

    def self.owner_message?(parsed)
      Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: parsed.from).exists?
    end

    def initialize(parsed, provider: ProviderFactory.build)
      @parsed = parsed
      @provider = provider
      @owner_whatsapp_number = parsed.from
      @account = Account.find_by!(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: @owner_whatsapp_number)
    end

    def call
      @account.with_lock do
        session = active_session || open_session_if_pending
        return handled(nil, send_owner_message("No tenés pendientes en Ayla.")) unless session
        return handled(session, true, duplicate: true) if duplicate_webhook?(session)

        remember_webhook!(session)
        body = @parsed.body.to_s.strip
        return finish_session(session) if body.match?(EXIT_COMMAND)
        return select_category(session, body.downcase) if body.downcase.in?(CATEGORIES)
        return handle_learning(session, body) if session.state == "awaiting_learning_confirmation"
        return skip_item(session) if body.match?(SKIP_COMMAND) && session.state == "awaiting_owner_reply"
        return answer_active_item(session, body) if session.state == "awaiting_owner_reply"

        show_menu(session)
      end
    end

    private

    def active_session
      session = @account.owner_whatsapp_sessions.active.order(created_at: :desc).first
      if session&.expires_at&.<=(Time.current)
        close_session!(session)
        Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
        return @account.owner_whatsapp_sessions.active.order(created_at: :desc).first
      end
      session
    end

    def open_session_if_pending
      Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider).session
    end

    def duplicate_webhook?(session)
      sid = message_sid
      sid.present? && Array(session.processed_message_sids).include?(sid)
    end

    def remember_webhook!(session)
      return if message_sid.blank?
      session.update!(processed_message_sids: (Array(session.processed_message_sids) + [message_sid]).last(100))
    end

    def message_sid
      @parsed.metadata.to_h["MessageSid"].presence || @parsed.metadata.to_h["SmsMessageSid"].presence
    end

    def select_category(session, category)
      item = pending_items(category).first
      unless item
        send_owner_message("No hay pendientes en #{category}.")
        return show_menu(session)
      end

      session.update!(
        state: "awaiting_owner_reply",
        active_category: category,
        active_item_type: item.class.base_class.name,
        active_item_id: item.id,
        last_owner_message_at: Time.current,
        expires_at: 30.minutes.from_now
      )
      send_owner_message(item_detail(item, category))
      handled(session, true, selected: true)
    end

    def answer_active_item(session, answer)
      return send_blank_answer(session) if answer.blank?
      item = validated_active_item(session)
      return invalid_active_item(session) unless item

      conversation = item.conversation
      return invalid_active_item(session) unless conversation&.guest&.phone_number.present?

      owner_message = conversation.messages.create!(
        sender: "owner", channel: "whatsapp", body: answer,
        metadata: { sent_via: "owner_whatsapp_queue", owner_phone_number: @owner_whatsapp_number,
                    active_item_type: session.active_item_type, active_item_id: session.active_item_id,
                    delivery_status: "pending", delivery_status_updated_at: Time.current.iso8601 }
      )
      delivery = @provider.send_message(to: conversation.guest.phone_number, body: answer)
      unless delivery_success?(delivery)
        owner_message.update!(metadata: owner_message.metadata.merge("delivery_status" => "failed", "delivery_error" => delivery_error(delivery)))
        send_owner_message("No pude enviar esa respuesta al huésped. El pendiente sigue abierto.")
        return handled(session, false)
      end

      owner_message.update!(metadata: owner_message.metadata.merge("delivery_status" => "sent"))
      item.update!(status: "resolved")
      session.update!(last_owner_message_at: Time.current)
      if session.active_category == "consultas"
        session.update!(state: "awaiting_learning_confirmation", metadata: session.metadata.merge(
          "learning_item_id" => item.id, "learning_owner_message_id" => owner_message.id, "learning_answer" => answer
        ))
        send_owner_message("¿Querés que Ayla recuerde esta respuesta para futuras consultas de esta propiedad? Respondé recordar o no_recordar.")
        return handled(session, true)
      end

      advance_or_finish(session)
    end

    def handle_learning(session, body)
      unless body.match?(REMEMBER_COMMAND) || body.match?(FORGET_COMMAND)
        send_owner_message("Respondé recordar o no_recordar.")
        return handled(session, true)
      end

      create_approved_faq!(session) if body.match?(REMEMBER_COMMAND)
      advance_or_finish(session)
    end

    def create_approved_faq!(session)
      item = @account.owner_tasks.inquiries.find_by(id: session.metadata["learning_item_id"])
      return unless item
      return if item.property.faqs.where("lower(question) = ?", item.current_guest_message.downcase).exists?

      item.property.faqs.create!(
        question: item.current_guest_message,
        answer: session.metadata["learning_answer"],
        category: "owner_answer",
        active: true,
        status: "approved",
        source_type: "owner_answer",
        source_message_id: session.metadata["learning_owner_message_id"],
        metadata: { "owner_id" => @account.id, "source_type" => "owner_answer", "source_id" => "owner_task.#{item.id}",
                    "status" => "approved", "property_id" => item.property_id }
      )
    end

    def skip_item(session)
      current_id = session.active_item_id
      item = pending_items(session.active_category).where.not(id: current_id).first
      return finish_session(session) unless item
      session.update!(active_item_type: item.class.base_class.name, active_item_id: item.id, expires_at: 30.minutes.from_now)
      send_owner_message(item_detail(item, session.active_category))
      handled(session, true)
    end

    def advance_or_finish(session)
      item = pending_items(session.active_category).first
      return finish_session(session) unless item
      session.update!(state: "awaiting_owner_reply", active_item_type: item.class.base_class.name, active_item_id: item.id,
                      expires_at: 30.minutes.from_now, metadata: session.metadata.except("learning_item_id", "learning_owner_message_id", "learning_answer"))
      send_owner_message(item_detail(item, session.active_category))
      handled(session, true)
    end

    def finish_session(session)
      close_session!(session)
      send_owner_message("Sesión finalizada.")
      result = Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
      handled(result.session || session, true, finished: true, follow_up_sent: result.sent?)
    end

    def close_session!(session)
      session.update!(state: "resolved", resolved_at: Time.current, active_category: nil, active_item_type: nil, active_item_id: nil)
    end

    def show_menu(session)
      counts = pending_counts
      send_owner_message("Elegí una categoría: pedidos (#{counts[:pedidos]}), consultas (#{counts[:consultas]}) o alertas (#{counts[:alertas]}).")
      handled(session, true, menu: true)
    end

    def pending_items(category)
      case category
      when "pedidos" then @account.owner_tasks.open.requests.order(:created_at)
      when "consultas" then @account.owner_tasks.open.inquiries.order(:created_at)
      when "alertas" then Alert.joins(:property).where(properties: { account_id: @account.id }).open.order(:created_at)
      else OwnerTask.none
      end
    end

    def pending_counts
      { pedidos: pending_items("pedidos").count, consultas: pending_items("consultas").count, alertas: pending_items("alertas").count }
    end

    def validated_active_item(session)
      item = session.active_item
      return unless item&.status == "open"
      return unless item.property.account_id == @account.id
      return unless item.class.base_class.name == session.active_item_type
      item
    end

    def item_detail(item, category)
      table = item.class.base_class.table_name
      position = pending_items(category).where("#{table}.created_at < ?", item.created_at).count + 1
      total = pending_items(category).count
      label = { "pedidos" => "Pedido", "consultas" => "Consulta", "alertas" => "Alerta" }.fetch(category)
      guest = item.guest&.phone_number.presence || "Huésped de WhatsApp"
      message = item.respond_to?(:current_guest_message) ? item.current_guest_message : (item.description.presence || item.title)
      "#{label} #{position} de #{total}\n\nPropiedad:\n#{item.property.display_name}\n\nHuésped:\n#{guest}\n\nMensaje:\n\n\"#{message}\"\n\nRespondé con el texto exacto para el huésped. También podés escribir siguiente, omitir o salir."
    end

    def send_blank_answer(session)
      send_owner_message("Escribí la respuesta para el huésped, o siguiente, omitir o salir.")
      handled(session, true)
    end

    def invalid_active_item(session)
      close_session!(session)
      send_owner_message("Ese pendiente ya no está disponible. No se envió ningún mensaje al huésped.")
      handled(session, false)
    end

    def send_owner_message(body)
      delivery_success?(@provider.send_message(to: @owner_whatsapp_number, body: body))
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_error(delivery)
      delivery.respond_to?(:error) && delivery.error.present? ? delivery.error : "whatsapp_delivery_failed"
    end

    def handled(session, replied, extras = {})
      { owner_message: true, handled: true, session: session, replied: replied }.merge(extras)
    end
  end
end
