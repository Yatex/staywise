module Whatsapp
  class OwnerInboundMessageHandler
    ACTION_IDS = {
      responder: "responder",
      siguiente: "siguiente",
      omitir: "omitir",
      salir: "salir",
      enviar: "enviar",
      editar: "editar",
      cancelar: "cancelar",
      recordar: "recordar",
      no_recordar: "no_recordar"
    }.freeze
    CATEGORIES = %w[pedidos consultas alertas].freeze
    ITEM_ACTIONS = ACTION_IDS.values_at(:responder, :siguiente, :omitir, :salir).freeze
    CONFIRMATION_ACTIONS = ACTION_IDS.values_at(:enviar, :editar, :cancelar).freeze
    LEARNING_ACTIONS = ACTION_IDS.values_at(:recordar, :no_recordar).freeze
    MAX_RECENT_MESSAGES = 6
    MAX_CONTEXT_LENGTH = 3_500

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
        return handled(active_session, true, duplicate: true) if duplicate_webhook?

        session = active_session || open_session_if_pending
        return handled(nil, send_owner_message("No tenés pendientes en Ayla.")) unless session

        remember_webhook!(session)
        return handle_menu(session) if session.state == "menu"
        return handle_viewing_item(session) if session.state == "viewing_item"
        return capture_reply_draft(session) if session.state == "awaiting_reply_text"
        return handle_send_confirmation(session) if session.state == "awaiting_send_confirmation"
        return handle_learning(session) if session.state == "awaiting_learning_confirmation"

        show_menu(session)
      end
    end

    private

    def handle_menu(session)
      category = action_id
      return select_category(session, category) if category.in?(CATEGORIES)
      return finish_session(session) if category == ACTION_IDS[:salir]

      show_menu(session)
    end

    def handle_viewing_item(session)
      case action_id
      when ACTION_IDS[:responder]
        session.update!(state: "awaiting_reply_text", draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil, expires_at: 30.minutes.from_now)
        send_owner_message("Escribí el mensaje exacto que querés enviarle al huésped.")
        handled(session, true)
      when ACTION_IDS[:siguiente], ACTION_IDS[:omitir]
        show_next_item(session)
      when ACTION_IDS[:salir]
        finish_session(session)
      else
        send_owner_message("Elegí una de las opciones para continuar.")
        send_item_actions
        handled(session, true)
      end
    end

    def capture_reply_draft(session)
      item = validated_active_item(session)
      return invalid_active_item(session) unless item
      draft = @parsed.body.to_s.strip
      if draft.blank? || @parsed.interactive_action_id.present?
        send_owner_message("Escribí el mensaje exacto que querés enviarle al huésped.")
        return handled(session, true)
      end

      session.update!(
        state: "awaiting_send_confirmation",
        draft_reply_body: draft,
        draft_item_type: session.active_item_type,
        draft_item_id: session.active_item_id,
        expires_at: 30.minutes.from_now
      )
      send_confirmation(draft)
      handled(session, true, draft_saved: true)
    end

    def handle_send_confirmation(session)
      case action_id
      when ACTION_IDS[:enviar]
        send_confirmed_reply(session)
      when ACTION_IDS[:editar]
        session.update!(state: "awaiting_reply_text", draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil, expires_at: 30.minutes.from_now)
        send_owner_message("Escribí nuevamente el mensaje que querés enviar.")
        handled(session, true)
      when ACTION_IDS[:cancelar]
        clear_draft!(session)
        show_active_item(session)
      else
        send_owner_message("Elegí Enviar, Editar o Cancelar para continuar.")
        send_confirmation(session.draft_reply_body.to_s)
        handled(session, true)
      end
    end

    def send_confirmed_reply(session)
      item = validated_active_item(session)
      return invalid_active_item(session) unless item && session.draft_for_active_item?
      conversation = item.conversation
      return invalid_active_item(session) unless conversation&.property_id == item.property_id
      return invalid_active_item(session) unless conversation.guest_id == item.guest_id && conversation.guest&.phone_number.present?

      draft = session.draft_reply_body
      owner_message = conversation.messages.create!(
        sender: "owner", channel: "whatsapp", body: draft,
        metadata: { sent_via: "owner_whatsapp_queue", owner_phone_number: @owner_whatsapp_number,
                    active_item_type: session.active_item_type, active_item_id: session.active_item_id,
                    delivery_status: "pending", delivery_status_updated_at: Time.current.iso8601 }
      )
      delivery = @provider.send_message(to: conversation.guest.phone_number, body: draft)
      unless delivery_success?(delivery)
        owner_message.update!(metadata: owner_message.metadata.merge("delivery_status" => "failed", "delivery_error" => delivery_error(delivery)))
        send_owner_message("No pude enviar esa respuesta. El pendiente sigue abierto y podés volver a intentar.")
        return handled(session, false)
      end

      owner_message.update!(metadata: owner_message.metadata.merge("delivery_status" => "sent"))
      item.update!(status: "resolved")
      session.update!(last_owner_message_at: Time.current, draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil)
      if session.active_category == "consultas"
        session.update!(state: "awaiting_learning_confirmation", metadata: session.metadata.merge(
          "learning_item_id" => item.id, "learning_owner_message_id" => owner_message.id, "learning_answer" => draft
        ))
        send_learning_options
        return handled(session, true)
      end

      advance_or_finish(session)
    end

    def handle_learning(session)
      unless action_id.in?(LEARNING_ACTIONS)
        send_owner_message("Elegí si querés que Ayla recuerde esta respuesta.")
        send_learning_options
        return handled(session, true)
      end

      create_approved_faq!(session) if action_id == ACTION_IDS[:recordar]
      advance_or_finish(session)
    end

    def select_category(session, category)
      item = pending_items(category).first
      unless item
        send_owner_message("No hay pendientes en #{category}.")
        return show_menu(session)
      end

      activate_item!(session, item, category)
      show_active_item(session)
    end

    def show_next_item(session)
      current = validated_active_item(session)
      return invalid_active_item(session) unless current
      scope = pending_items(session.active_category).where.not(id: session.active_item_id)
      table = current.class.base_class.table_name
      item = scope.where("#{table}.created_at > ?", current.created_at).first || scope.first
      return finish_session(session) unless item

      activate_item!(session, item, session.active_category)
      show_active_item(session)
    end

    def advance_or_finish(session)
      item = pending_items(session.active_category).first
      return finish_session(session) unless item

      activate_item!(session, item, session.active_category)
      session.update!(metadata: session.metadata.except("learning_item_id", "learning_owner_message_id", "learning_answer"))
      show_active_item(session)
    end

    def activate_item!(session, item, category)
      session.update!(
        state: "viewing_item", active_category: category,
        active_item_type: item.class.base_class.name, active_item_id: item.id,
        draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil,
        last_owner_message_at: Time.current, expires_at: 30.minutes.from_now
      )
    end

    def show_active_item(session)
      item = validated_active_item(session)
      return invalid_active_item(session) unless item

      session.update!(state: "viewing_item", draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil, expires_at: 30.minutes.from_now)
      send_owner_message(item_detail(item, session.active_category))
      send_item_actions
      handled(session, true, selected: true)
    end

    def item_detail(item, category)
      table = item.class.base_class.table_name
      position = pending_items(category).where("#{table}.created_at < ?", item.created_at).count + 1
      total = pending_items(category).count
      label = { "pedidos" => "Pedido", "consultas" => "Consulta", "alertas" => "Alerta" }.fetch(category)
      original = original_item_message(item)
      clarifications = item_clarifications(item)
      recent = recent_conversation(item)
      last_guest = item.conversation&.messages&.where(sender: "guest")&.order(created_at: :desc)&.first&.body

      sections = [
        "#{label} #{position} de #{total}",
        "Caso ##{case_identifier(item, category)}",
        "Propiedad:\n#{item.property.display_name}",
        "Huésped:\n#{item.guest&.phone_number.presence || 'Huésped de WhatsApp'}",
        "Solicitud original:\n“#{clean_context_body(original, item.property)}”"
      ]
      sections << "Aclaraciones:\n#{clarifications.map { |body| "“#{clean_context_body(body, item.property)}”" }.join("\n")}" if clarifications.any?
      sections << "Conversación reciente:\n\n#{recent}" if recent.present?
      sections << "Último mensaje del huésped:\n“#{clean_context_body(last_guest, item.property)}”" if last_guest.present?
      sections.join("\n\n").truncate(MAX_CONTEXT_LENGTH)
    end

    def original_item_message(item)
      if item.is_a?(OwnerTask)
        item.message&.body.presence || item.description
      else
        item.original_message&.body.presence || item.description.presence || item.title
      end
    end

    def item_clarifications(item)
      return [] unless item.respond_to?(:metadata)

      Array(item.metadata.to_h["updates"]).filter_map { |update| update.to_h["body"].to_s.strip.presence }.last(3)
    end

    def recent_conversation(item)
      conversation = item.conversation
      return if conversation.blank?
      anchor = item.respond_to?(:message) ? item.message : item.original_message
      scope = conversation.messages.order(created_at: :desc)
      scope = scope.where("created_at >= ?", anchor.created_at - 5.minutes) if anchor&.created_at
      messages = scope.limit(MAX_RECENT_MESSAGES).to_a.reverse
      messages.map do |message|
        speaker = { "guest" => "Huésped", "ai" => "Ayla", "owner" => "Anfitrión" }.fetch(message.sender, "Ayla")
        "#{speaker}:\n“#{clean_context_body(message.body, item.property).truncate(500)}”"
      end.join("\n\n")
    end

    def clean_context_body(body, property)
      body.to_s.gsub(property.whatsapp_reference.to_s, "").squish.presence || "Sin mensaje disponible"
    end

    def case_identifier(item, category)
      prefix = { "pedidos" => "P", "consultas" => "C", "alertas" => "A" }.fetch(category)
      "#{prefix}-#{item.id}"
    end

    def send_item_actions
      send_interactive(
        content_key: :item_actions,
        fallback_body: "Opciones: responder, siguiente, omitir o salir."
      )
    end

    def send_confirmation(draft)
      send_interactive(
        content_key: :confirm_reply,
        variables: { "1" => draft },
        fallback_body: "Vas a enviar al huésped:\n\n“#{draft}”\n\n¿Está correcto? Respondé enviar, editar o cancelar."
      )
    end

    def send_learning_options
      send_interactive(
        content_key: :learning,
        fallback_body: "¿Querés que Ayla recuerde esta respuesta? Opciones: recordar o no_recordar."
      )
    end

    def send_interactive(content_key:, fallback_body:, variables: {})
      delivery = @provider.send_interactive(to: @owner_whatsapp_number, content_key: content_key, variables: variables, fallback_body: fallback_body)
      delivery_success?(delivery)
    end

    def action_id
      interactive = @parsed.interactive_action_id.to_s.strip.downcase
      return interactive if (ACTION_IDS.values + CATEGORIES).include?(interactive)

      typed = @parsed.body.to_s.strip.downcase
      allowed = case active_session&.state
      when "menu" then CATEGORIES + [ACTION_IDS[:salir]]
      when "viewing_item" then ITEM_ACTIONS
      when "awaiting_send_confirmation" then CONFIRMATION_ACTIONS
      when "awaiting_learning_confirmation" then LEARNING_ACTIONS
      else []
      end
      allowed.include?(typed) ? typed : nil
    end

    def create_approved_faq!(session)
      item = @account.owner_tasks.inquiries.find_by(id: session.metadata["learning_item_id"])
      return unless item
      return if item.property.faqs.where("lower(question) = ?", item.current_guest_message.downcase).exists?

      item.property.faqs.create!(
        question: item.current_guest_message, answer: session.metadata["learning_answer"], category: "owner_answer",
        active: true, status: "approved", source_type: "owner_answer", source_message_id: session.metadata["learning_owner_message_id"],
        metadata: { "owner_id" => @account.id, "source_type" => "owner_answer", "source_id" => "owner_task.#{item.id}",
                    "status" => "approved", "property_id" => item.property_id }
      )
    end

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
      return if pending_counts.values.sum.zero?

      session = @account.owner_whatsapp_sessions.where(state: %w[queued on_hold]).order(updated_at: :desc).first
      if session
        session.update!(state: "menu", started_at: session.started_at || Time.current, expires_at: 30.minutes.from_now)
        return session
      end

      @account.owner_whatsapp_sessions.create!(state: "menu", started_at: Time.current, expires_at: 30.minutes.from_now)
    end

    def duplicate_webhook?
      return false if message_sid.blank?
      @account.owner_whatsapp_sessions.order(created_at: :desc).limit(20).any? do |session|
        Array(session.processed_message_sids).include?(message_sid)
      end
    end

    def remember_webhook!(session)
      return if message_sid.blank?
      session.update!(processed_message_sids: (Array(session.processed_message_sids) + [message_sid]).last(100))
    end

    def message_sid
      @parsed.metadata.to_h["MessageSid"].presence || @parsed.metadata.to_h["SmsMessageSid"].presence
    end

    def finish_session(session)
      close_session!(session)
      send_owner_message("Sesión finalizada.")
      result = Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
      handled(result.session || session, true, finished: true, follow_up_sent: result.sent?)
    end

    def close_session!(session)
      session.update!(state: "resolved", resolved_at: Time.current, active_category: nil, active_item_type: nil, active_item_id: nil,
                      draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil)
    end

    def clear_draft!(session)
      session.update!(draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil)
    end

    def invalid_active_item(session)
      close_session!(session)
      send_owner_message("Ese pendiente ya no está disponible. No se envió ningún mensaje al huésped.")
      Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
      handled(session, false)
    end

    def show_menu(session)
      counts = pending_counts
      template_sid = ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
      if template_sid.present?
        @provider.send_template(
          to: @owner_whatsapp_number,
          template_sid: template_sid,
          variables: { "1" => counts[:pedidos].to_s, "2" => counts[:consultas].to_s, "3" => counts[:alertas].to_s }
        )
      else
        send_owner_message("Elegí una categoría: pedidos (#{counts[:pedidos]}), consultas (#{counts[:consultas]}) o alertas (#{counts[:alertas]}).")
      end
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
