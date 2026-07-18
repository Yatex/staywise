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
      no_recordar: "no_recordar",
      checkout_visto: "checkout_visto"
    }.freeze
    CATEGORIES = %w[pedidos consultas alertas checkouts].freeze
    ITEM_ACTIONS = ACTION_IDS.values_at(:responder, :siguiente, :omitir, :salir).freeze
    CONFIRMATION_ACTIONS = ACTION_IDS.values_at(:enviar, :editar, :cancelar).freeze
    LEARNING_ACTIONS = ACTION_IDS.values_at(:recordar, :no_recordar).freeze
    CHECKOUT_ACTIONS = ACTION_IDS.values_at(:checkout_visto, :siguiente, :salir).freeze
    MAX_RECENT_MESSAGES = 6
    MAX_CONTEXT_LENGTH = 3_500

    def self.owner_message?(parsed)
      HostActor.authorized_phone?(parsed.from)
    end

    def initialize(parsed, provider: ProviderFactory.build)
      @parsed = parsed
      @provider = provider
      @owner_whatsapp_number = parsed.from
      @actor = HostActor.resolve(@owner_whatsapp_number)
      @account = @actor.account
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
      return handle_checkout_item(session) if session.active_category == "checkouts"

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

    def handle_checkout_item(session)
      case action_id
      when ACTION_IDS[:checkout_visto]
        event = validated_active_item(session)
        return invalid_active_item(session) unless event

        event.mark_seen!
        advance_or_finish(session)
      when ACTION_IDS[:siguiente]
        show_next_item(session)
      when ACTION_IDS[:salir]
        finish_session(session)
      else
        send_owner_message("Elegí Marcar como visto, Siguiente o Salir para continuar.")
        send_checkout_actions
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
      item = session.active_item
      return invalid_active_item(session) unless item && session.draft_for_active_item?
      return invalid_active_item(session) unless @actor.can_manage_property?(item.property)
      conversation = item.conversation
      return invalid_active_item(session) unless conversation&.property_id == item.property_id
      return invalid_active_item(session) unless conversation.guest_id == item.guest_id && conversation.guest&.phone_number.present?

      delivery = HostReplyDelivery.new(
        item: item, actor: @actor, session: session, provider: @provider, source_message_sid: message_sid
      ).call
      if delivery.already_handled?
        clear_draft!(session)
        send_owner_message(already_responded_message(item))
        return advance_or_finish(session)
      end
      unless delivery.sent?
        send_owner_message("No pude enviar esa respuesta. El pendiente sigue abierto y podés volver a intentar.")
        return handled(session, false)
      end

      session.update!(last_owner_message_at: Time.current, draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil)
      if session.active_category == "consultas"
        session.update!(state: "awaiting_learning_confirmation", metadata: session.metadata.merge(
          "learning_item_id" => item.id, "learning_owner_message_id" => delivery.owner_message.id,
          "learning_answer" => item.final_response_body, "learning_actor_type" => @actor.type, "learning_actor_id" => @actor.id
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
      session.active_category == "checkouts" ? send_checkout_actions : send_item_actions
      handled(session, true, selected: true)
    end

    def item_detail(item, category)
      return checkout_detail(item) if category == "checkouts"

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

    def checkout_detail(event)
      table = event.class.base_class.table_name
      position = pending_items("checkouts").where("#{table}.created_at < ?", event.created_at).count + 1
      total = pending_items("checkouts").count
      guest = event.guest
      guest_label = [guest&.name.presence, guest&.phone_number.presence].compact.join(" · ").presence || "Huésped de WhatsApp"

      [
        "Checkout #{position} de #{total}",
        "Caso ##{case_identifier(event, 'checkouts')}",
        "Propiedad:\n#{event.property.display_name}",
        "Huésped:\n#{guest_label}",
        "Salida informada:\n#{I18n.l(event.checked_out_at, format: :long)}",
        "Mensaje del huésped:\n“#{clean_context_body(event.guest_message_body, event.property)}”",
        "El departamento ya puede revisarse."
      ].join("\n\n").truncate(MAX_CONTEXT_LENGTH)
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
      prefix = { "pedidos" => "P", "consultas" => "C", "alertas" => "A", "checkouts" => "CO" }.fetch(category)
      "#{prefix}-#{item.id}"
    end

    def send_item_actions
      send_interactive(
        content_key: :item_actions,
        fallback_body: "Opciones: responder, siguiente, omitir o salir."
      )
    end

    def send_checkout_actions
      send_interactive(
        content_key: :checkout_actions,
        fallback_body: "Opciones: checkout_visto, siguiente o salir."
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
      when "viewing_item" then active_session&.active_category == "checkouts" ? CHECKOUT_ACTIONS : ITEM_ACTIONS
      when "awaiting_send_confirmation" then CONFIRMATION_ACTIONS
      when "awaiting_learning_confirmation" then LEARNING_ACTIONS
      else []
      end
      allowed.include?(typed) ? typed : nil
    end

    def create_approved_faq!(session)
      item = @account.owner_tasks.inquiries.find_by(id: session.metadata["learning_item_id"])
      return unless item
      return unless @actor.can_manage_property?(item.property)
      return unless session.metadata["learning_actor_type"] == @actor.type && session.metadata["learning_actor_id"] == @actor.id
      return if item.property.faqs.where("lower(question) = ?", item.current_guest_message.downcase).exists?

      item.property.faqs.create!(
        question: item.current_guest_message, answer: session.metadata["learning_answer"], category: "owner_answer",
        active: true, status: "approved", source_type: "owner_answer", source_message_id: session.metadata["learning_owner_message_id"],
        metadata: { "owner_id" => @account.id, "source_type" => "owner_answer", "source_id" => "owner_task.#{item.id}",
                    "status" => "approved", "property_id" => item.property_id }
      )
    end

    def active_session
      session = participant_sessions.active.order(created_at: :desc).first
      if session&.expires_at&.<=(Time.current)
        close_session!(session)
        Whatsapp::OwnerEscalationNotifier.call(actor: @actor, provider: @provider)
        return participant_sessions.active.order(created_at: :desc).first
      end
      session
    end

    def open_session_if_pending
      return if pending_counts.values.sum.zero?

      session = participant_sessions.where(state: %w[queued on_hold]).order(updated_at: :desc).first
      if session
        session.update!(state: "menu", started_at: session.started_at || Time.current, expires_at: 30.minutes.from_now)
        return session
      end

      participant_sessions.create!(state: "menu", started_at: Time.current, expires_at: 30.minutes.from_now,
                                   actor_role: @actor.role, co_host: @actor.co_host)
    end

    def duplicate_webhook?
      return false if message_sid.blank?
      participant_sessions.order(created_at: :desc).limit(20).any? do |session|
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
      result = Whatsapp::OwnerEscalationNotifier.call(actor: @actor, provider: @provider)
      Whatsapp::ObserverNotifier.call(actor: @actor, provider: @provider) unless result.sent?
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
      result = Whatsapp::OwnerEscalationNotifier.call(actor: @actor, provider: @provider)
      Whatsapp::ObserverNotifier.call(actor: @actor, provider: @provider) unless result.sent?
      handled(session, false)
    end

    def show_menu(session)
      counts = pending_counts
      template_sid = ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
      if template_sid.present?
        @provider.send_template(
          to: @owner_whatsapp_number,
          template_sid: template_sid,
          variables: initial_notice_variables(template_sid, counts)
        )
      else
        send_owner_message("Elegí una categoría: pedidos (#{counts[:pedidos]}), consultas (#{counts[:consultas]}), alertas (#{counts[:alertas]}) o checkouts (#{counts[:checkouts]}).")
      end
      handled(session, true, menu: true)
    end

    def pending_items(category)
      case category
      when "pedidos" then response_pending(@account.owner_tasks.open.requests.where(property_id: @actor.property_ids)).order(:created_at)
      when "consultas" then response_pending(@account.owner_tasks.open.inquiries.where(property_id: @actor.property_ids)).order(:created_at)
      when "alertas" then response_pending(Alert.where(property_id: @actor.property_ids).open).order(:created_at)
      when "checkouts" then @account.checkout_events.pending.where(property_id: @actor.property_ids).order(:created_at)
      else OwnerTask.none
      end
    end

    def pending_counts
      { pedidos: pending_items("pedidos").count, consultas: pending_items("consultas").count, alertas: pending_items("alertas").count, checkouts: pending_items("checkouts").count }
    end

    def validated_active_item(session)
      item = session.active_item
      return unless item && (item.is_a?(CheckoutEvent) ? item.pending? : item.status == "open")
      return unless @actor.can_manage_property?(item.property)
      return unless item.class.base_class.name == session.active_item_type
      return if item.respond_to?(:response_delivery_state) && item.response_delivery_state.in?(%w[sending responded])
      if item.respond_to?(:response_delivery_state) && item.response_delivery_state == "failed"
        return unless item.resolved_by_actor_type == @actor.type && item.resolved_by_actor_id == @actor.id
      end
      item
    end

    def response_pending(scope)
      pending = scope.where(response_delivery_state: "pending")
      retryable = scope.where(
        response_delivery_state: "failed",
        resolved_by_actor_type: @actor.type,
        resolved_by_actor_id: @actor.id
      )
      pending.or(retryable)
    end

    def participant_sessions
      @account.owner_whatsapp_sessions.where(participant_phone: @actor.phone_number)
    end

    def already_responded_message(item)
      text = item.final_response_body.presence || item.claimed_response_body
      message = "Este caso ya fue respondido por otra persona autorizada."
      message += "\n\nRespuesta enviada:\n“#{text}”" if text.present? && item.response_delivery_state == "responded"
      message
    end

    def initial_notice_variables(template_sid, counts)
      variables = { "1" => counts[:pedidos].to_s, "2" => counts[:consultas].to_s, "3" => counts[:alertas].to_s }
      variables["4"] = counts[:checkouts].to_s if template_supports_checkouts?(template_sid)
      variables
    end

    def template_supports_checkouts?(template_sid)
      @provider.respond_to?(:template_supports_action?) && @provider.template_supports_action?(template_sid, "checkouts")
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
