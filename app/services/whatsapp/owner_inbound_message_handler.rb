module Whatsapp
  class OwnerInboundMessageHandler
    ACTION_IDS = {
      responder: "responder",
      siguiente: "siguiente",
      omitir: "omitir",
      salir: "salir",
      enviar: "enviar",
      traducir: "traducir",
      reintentar: "reintentar",
      enviar_traduccion: "enviar traduccion",
      enviar_original: "enviar original",
      editar_traduccion: "editar traduccion",
      editar_original: "editar original",
      editar: "editar",
      cancelar: "cancelar",
      recordar: "recordar",
      no_recordar: "no_recordar",
      checkout_visto: "checkout_visto",
      menu: "menu",
      ayuda: "ayuda"
    }.freeze
    CATEGORIES = %w[pedidos consultas alertas checkouts].freeze
    ITEM_ACTIONS = ACTION_IDS.values_at(:responder, :siguiente, :omitir, :salir).freeze
    CONFIRMATION_ACTIONS = ACTION_IDS.values_at(
      :enviar, :traducir, :reintentar, :enviar_traduccion, :enviar_original,
      :editar, :editar_traduccion, :editar_original, :cancelar
    ).freeze
    LEARNING_ACTIONS = ACTION_IDS.values_at(:recordar, :no_recordar).freeze
    CHECKOUT_ACTIONS = ACTION_IDS.values_at(:checkout_visto, :siguiente, :salir).freeze
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
      delivery_session_id = nil
      result = @account.with_lock do
        return handled(active_session, true, duplicate: true) if duplicate_webhook?

        session = active_session || open_session_if_pending
        return handle_without_session unless session

        remember_webhook!(session)
        @current_action = resolve_action(session)
        return handle_menu(session) if session.state == "menu"
        return handle_viewing_item(session) if session.state == "viewing_item"
        return capture_reply_draft(session) if session.state == "awaiting_reply_text"
        if session.state == "awaiting_send_confirmation" &&
            @current_action.in?(ACTION_IDS.values_at(:enviar, :enviar_traduccion, :enviar_original))
          unless prepare_reply_version!(session, @current_action)
            send_owner_message("No hay una traducción lista. Elegí Traducir o Enviar original.")
            return handled(session, false)
          end
          if prepare_confirmed_reply!(session)
            delivery_session_id = session.id
            next handled(session, true, sending: true)
          end
          return invalid_active_item(session)
        end
        return handle_send_confirmation(session) if session.state == "awaiting_send_confirmation"
        return handle_sending_message(session) if session.state == "sending_guest_message"
        return handle_learning(session) if session.state == "awaiting_learning_confirmation"
        return load_next_case(session) if session.state == "loading_next_case"

        show_menu(session)
      end
      return deliver_confirmed_reply(delivery_session_id) if delivery_session_id

      result
    end

    private

    def handle_menu(session)
      category = @current_action
      return select_category(session, category) if category.in?(CATEGORIES)
      return finish_session(session) if category == ACTION_IDS[:salir]
      return show_menu(session) if category == ACTION_IDS[:menu]

      send_owner_message(menu_guidance)
      handled(session, true, help: true)
    end

    def handle_viewing_item(session)
      return handle_checkout_item(session) if session.active_category == "checkouts"

      case @current_action
      when ACTION_IDS[:responder]
        session.update!(state: "awaiting_reply_text", draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil, expires_at: 30.minutes.from_now)
        send_owner_message("Escribí el mensaje exacto que querés enviarle al huésped.")
        handled(session, true)
      when ACTION_IDS[:siguiente], ACTION_IDS[:omitir]
        show_next_item(session)
      when ACTION_IDS[:salir]
        finish_session(session)
      else
        send_owner_guidance("Para este caso podés elegir Responder, Siguiente, Omitir o Salir.")
        send_item_actions
        handled(session, true)
      end
    end

    def handle_checkout_item(session)
      case @current_action
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
        send_owner_guidance("Para esta salida podés elegir Marcar como visto, Siguiente o Salir.")
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

      if session.metadata["reply_edit_target"] == "translation"
        reply_draft = OwnerReplyDraft.find_by(id: session.metadata["owner_reply_draft_id"])
        return invalid_active_item(session) unless reply_draft
        reply_draft.update!(translated_body: draft, translation_status: "completed")
        session.update!(state: "awaiting_send_confirmation",
          metadata: session.metadata.except("reply_edit_target"), expires_at: 30.minutes.from_now)
        send_translation_confirmation(reply_draft)
        return handled(session, true, draft_saved: true)
      end

      reply_draft = OwnerReplyDraft.create!(
        conversation: item.conversation,
        co_host: @actor.co_host,
        original_body: draft,
        source_language: actor_language,
        target_language: item.conversation.guest.language.presence || "es"
      )
      session.update!(
        state: "awaiting_send_confirmation",
        draft_reply_body: draft,
        draft_item_type: session.active_item_type,
        draft_item_id: session.active_item_id,
        metadata: session.metadata.merge("owner_reply_draft_id" => reply_draft.id),
        expires_at: 30.minutes.from_now
      )
      send_confirmation(draft, item: item)
      handled(session, true, draft_saved: true)
    end

    def handle_send_confirmation(session)
      case @current_action
      when ACTION_IDS[:traducir], ACTION_IDS[:reintentar]
        translate_reply_draft(session)
      when ACTION_IDS[:editar_traduccion]
        session.update!(state: "awaiting_reply_text",
          metadata: session.metadata.merge("reply_edit_target" => "translation"), expires_at: 30.minutes.from_now)
        send_owner_message("Escribí la traducción corregida.")
        handled(session, true)
      when ACTION_IDS[:editar_original]
        invalidate_session_translation(session)
        session.update!(state: "awaiting_reply_text", draft_reply_body: nil,
          draft_item_type: nil, draft_item_id: nil, expires_at: 30.minutes.from_now)
        send_owner_message("Escribí nuevamente el mensaje original.")
        handled(session, true)
      when ACTION_IDS[:editar]
        invalidate_session_translation(session)
        session.update!(state: "awaiting_reply_text", draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil, expires_at: 30.minutes.from_now)
        send_owner_message("Escribí nuevamente el mensaje que querés enviar.")
        handled(session, true)
      when ACTION_IDS[:cancelar]
        clear_draft!(session)
        show_active_item(session)
      else
        send_owner_guidance("Tenés una respuesta preparada. Elegí Enviar, Traducir, Editar o Cancelar para continuar.")
        send_confirmation(session.draft_reply_body.to_s, item: session.active_item)
        handled(session, true)
      end
    end

    def handle_sending_message(session)
      send_owner_guidance("Estoy enviando la respuesta anterior. No hace falta que vuelvas a tocar Enviar.")
      handled(session, true, sending: true)
    end

    def prepare_confirmed_reply!(session)
      item = session.active_item
      return false unless item && session.draft_for_active_item?
      return false unless @actor.can_manage_property?(item.property)
      conversation = item.conversation
      return false unless conversation&.property_id == item.property_id
      return false unless conversation.guest_id == item.guest_id && conversation.guest&.phone_number.present?

      session.update!(state: "sending_guest_message", expires_at: 30.minutes.from_now)
      true
    end

    def prepare_reply_version!(session, action)
      draft = OwnerReplyDraft.find_by(id: session.metadata["owner_reply_draft_id"])
      return true if action == ACTION_IDS[:enviar]
      return false if draft.blank?

      if action == ACTION_IDS[:enviar_traduccion] && draft.translation_status == "completed"
        session.update!(draft_reply_body: draft.translated_body,
          metadata: session.metadata.merge("reply_version" => "translated"))
        true
      elsif action == ACTION_IDS[:enviar_original]
        session.update!(draft_reply_body: draft.original_body,
          metadata: session.metadata.merge("reply_version" => "original"))
        true
      else
        false
      end
    end

    def translate_reply_draft(session)
      draft = OwnerReplyDraft.find_by(id: session.metadata["owner_reply_draft_id"])
      return invalid_active_item(session) unless draft
      draft.update!(translation_status: "pending")
      if Translation::ReplyDraftTranslator.call(draft: draft)
        send_translation_confirmation(draft)
      else
        send_owner_message("No pude traducir el borrador. Podés escribir Reintentar, Enviar original o Cancelar.")
      end
      handled(session, true)
    end

    def invalidate_session_translation(session)
      draft = OwnerReplyDraft.find_by(id: session.metadata["owner_reply_draft_id"])
      draft&.invalidate_translation!(draft.original_body)
    end

    def send_translation_confirmation(draft)
      send_owner_message(
        "Tu mensaje:\n#{draft.original_body}\n\nEl huésped recibirá:\n#{draft.translated_body}\n\n" \
        "Opciones: Enviar traducción, Editar traducción, Editar original, Enviar original o Cancelar."
      )
    end

    def actor_language
      @actor.co_host&.preferred_conversation_language.presence ||
        @account.users.find_by(role: "owner")&.preferred_conversation_language.presence || "es"
    end

    def deliver_confirmed_reply(session_id)
      session = participant_sessions.find(session_id)
      item = session.active_item
      return invalid_active_item(session) unless item && session.state == "sending_guest_message" && session.draft_for_active_item?
      category = session.active_category

      delivery = HostReplyDelivery.new(
        item: item, actor: @actor, session: session, provider: @provider, source_message_sid: message_sid,
        on_success: ->(resolved_item, owner_message) { finalize_sent_case!(session, resolved_item, owner_message, category) },
        on_failure: ->(_failed_item) { restore_failed_confirmation!(session) }
      ).call
      if delivery.already_handled?
        send_owner_message(already_responded_message(item))
        return reconcile_already_handled_case(session, item)
      end
      unless delivery.sent?
        send_owner_message("No pude enviar esa respuesta. El pendiente sigue abierto y podés volver a intentar.")
        return handled(session, false)
      end

      if category == "consultas"
        send_learning_options
        return handled(session, true)
      end

      load_next_case(session)
    end

    def handle_learning(session)
      unless @current_action.in?(LEARNING_ACTIONS)
        send_owner_guidance("Elegí Recordar o No recordar para indicar si Ayla debe guardar esta respuesta.")
        send_learning_options
        return handled(session, true)
      end

      create_approved_faq!(session) if @current_action == ACTION_IDS[:recordar]
      prepare_loading_next!(session)
      load_next_case(session)
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
      category = session.active_category
      previous_id = session.active_item_id
      previous_item = session.active_item
      scope = pending_items(category).where.not(id: previous_id)
      item = if previous_item
        table = previous_item.class.base_class.table_name
        scope.where("#{table}.created_at > ?", previous_item.created_at).first || scope.first
      else
        scope.first
      end
      unless item
        if pending_items(category).where(id: previous_id).exists?
          send_owner_message("No hay otro pendiente en #{category}. Este caso sigue abierto.")
          session.active_category == "checkouts" ? send_checkout_actions : send_item_actions
          return handled(session, true)
        end

        prepare_loading_next!(session)
        return load_next_case(session)
      end

      activate_item!(session, item, category)
      show_active_item(session)
    end

    def advance_or_finish(session)
      prepare_loading_next!(session)
      load_next_case(session)
    end

    def load_next_case(session)
      session.reload
      category = session.active_category
      item = pending_items(category).first
      return finish_session(session, no_more: true, category: category) unless item

      activate_item!(session, item, category)
      show_active_item(session)
    end

    def prepare_loading_next!(session)
      session.update!(
        state: "loading_next_case",
        active_item_type: nil,
        active_item_id: nil,
        draft_reply_body: nil,
        draft_item_type: nil,
        draft_item_id: nil,
        metadata: session.metadata.except(
          "learning_item_id", "learning_owner_message_id", "learning_answer",
          "learning_actor_type", "learning_actor_id", "owner_reply_draft_id",
          "reply_version", "reply_edit_target"
        ),
        expires_at: 30.minutes.from_now
      )
    end

    def finalize_sent_case!(session, item, owner_message, category)
      if (reply_draft = OwnerReplyDraft.find_by(id: session.metadata["owner_reply_draft_id"]))
        reply_draft.update!(
          sent_body: owner_message.body,
          translation_status: "sent",
          confirmed_by: @owner_whatsapp_number,
          confirmed_at: Time.current
        )
      end
      attributes = {
        last_owner_message_at: Time.current,
        active_item_type: nil,
        active_item_id: nil,
        draft_reply_body: nil,
        draft_item_type: nil,
        draft_item_id: nil,
        expires_at: 30.minutes.from_now
      }
      if category == "consultas"
        attributes[:state] = "awaiting_learning_confirmation"
        attributes[:metadata] = session.metadata.merge(
          "learning_item_id" => item.id,
          "learning_owner_message_id" => owner_message.id,
          "learning_answer" => item.final_response_body,
          "learning_actor_type" => @actor.type,
          "learning_actor_id" => @actor.id
        )
      else
        attributes[:state] = "loading_next_case"
      end
      session.update!(attributes)
    end

    def restore_failed_confirmation!(session)
      session.reload
      return unless session.state == "sending_guest_message"

      session.update!(state: "awaiting_send_confirmation", expires_at: 30.minutes.from_now)
    end

    def reconcile_already_handled_case(session, item)
      item.reload
      if item.response_delivery_state.in?(%w[sending responded]) || item.status == "resolved"
        prepare_loading_next!(session)
        load_next_case(session)
      else
        restore_failed_confirmation!(session)
        handled(session, false)
      end
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
      identifier = case_identifier(item, category)
      title = item.title.presence || "#{label} ##{identifier}"

      sections = [
        "#{label} #{position} de #{total}",
        "Caso ##{identifier}",
        title,
        "Propiedad:\n#{item.property.display_name}",
        "Huésped:\n#{item.guest&.phone_number.presence || 'Huésped de WhatsApp'}",
        "Ver conversación:\n#{conversation_url(item.conversation)}"
      ]
      if item.is_a?(Alert) && critical_alert?(item)
        critical_detail = item.description.to_s.squish
        sections << "Atención inmediata:\n#{critical_detail.truncate(180)}" if critical_detail.present? && critical_detail != title
      end
      sections.join("\n\n")
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
        "Estado:\n#{event.pending? ? 'Pendiente de revisión' : 'Visto'}",
        "Ver conversación:\n#{conversation_url(event.conversation)}"
      ].join("\n\n")
    end

    def critical_alert?(alert)
      alert.alert_type == "emergency" || alert.priority == "urgent"
    end

    def conversation_url(conversation)
      Rails.application.routes.url_helpers.conversation_url(
        conversation,
        host: ENV["APP_HOST"].presence || "http://localhost:3000"
      )
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

    def send_confirmation(draft, item:)
      language = guest_language_label(item)
      send_interactive(
        content_key: :confirm_reply,
        variables: { "1" => draft, "2" => language },
        fallback_body: [
          "Vas a enviar al huésped:",
          "“#{draft}”",
          "Idioma del huésped: #{language}.",
          "Opciones: enviar, traducir, editar o cancelar."
        ].join("\n\n")
      )
    end

    def guest_language_label(item)
      code = AI::LanguageHelper.normalize_code(item&.conversation&.guest&.language).presence || "es"

      I18n.t("ui.language_names.#{code}", locale: :es, default: code.upcase).to_s.downcase
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

    def resolve_action(session)
      interactive = normalize_command(@parsed.interactive_action_id)
      return interactive if (ACTION_IDS.values + CATEGORIES).include?(interactive)

      typed = normalize_command(@parsed.body)
      return typed if typed.in?(ACTION_IDS.values_at(:menu, :ayuda)) && session.state != "awaiting_reply_text"

      allowed = case session.state
      when "menu" then CATEGORIES + ACTION_IDS.values_at(:salir, :menu, :ayuda)
      when "viewing_item" then session.active_category == "checkouts" ? CHECKOUT_ACTIONS : ITEM_ACTIONS
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

    def finish_session(session, no_more: false, category: nil)
      close_session!(session)
      if no_more
        label = category.presence || "esta categoría"
        send_owner_message("No hay más pendientes en #{label}.")
      else
        send_owner_message("Sesión finalizada.")
      end
      result = Whatsapp::OwnerEscalationNotifier.call(actor: @actor, provider: @provider)
      handled(result.session || session, true, finished: true, follow_up_sent: result.sent?)
    end

    def close_session!(session)
      session.update!(state: "resolved", resolved_at: Time.current, active_category: nil, active_item_type: nil, active_item_id: nil,
                      draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil,
                      metadata: session.metadata.except(
                        "learning_item_id", "learning_owner_message_id", "learning_answer",
                        "learning_actor_type", "learning_actor_id", "owner_reply_draft_id",
                        "reply_version", "reply_edit_target"
                      ))
    end

    def clear_draft!(session)
      OwnerReplyDraft.find_by(id: session.metadata["owner_reply_draft_id"])&.update!(translation_status: "cancelled")
      session.update!(draft_reply_body: nil, draft_item_type: nil, draft_item_id: nil,
        metadata: session.metadata.except("owner_reply_draft_id", "reply_version", "reply_edit_target"))
    end

    def invalid_active_item(session)
      close_session!(session)
      send_owner_message("Ese pendiente ya no está disponible. No se envió ningún mensaje al huésped.")
      Whatsapp::OwnerEscalationNotifier.call(actor: @actor, provider: @provider)
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

    def handle_without_session
      counts = pending_counts
      message = if normalized_typed_action == ACTION_IDS[:menu]
        menu_guidance(counts)
      else
        [
          owner_role_explanation,
          "No tenés pedidos, consultas, alertas ni salidas pendientes.",
          owner_available_actions
        ].join("\n\n")
      end

      handled(nil, send_owner_message(message), help: true, menu: normalized_typed_action == ACTION_IDS[:menu])
    end

    def send_owner_guidance(detail)
      send_owner_message([owner_role_explanation, detail, owner_available_actions].join("\n\n"))
    end

    def owner_role_explanation
      "Este número está configurado como WhatsApp del *dueño/anfitrión*. Ayla interpreta tus mensajes como acciones del dueño, no como preguntas de un huésped."
    end

    def owner_available_actions
      "Escribí *MENÚ* para ver tus pendientes o *AYUDA* para conocer las opciones. Para probar Ayla como huésped, usá otro número de WhatsApp."
    end

    def menu_guidance(counts = pending_counts)
      [
        owner_role_explanation,
        "Pendientes: pedidos (#{counts[:pedidos]}), consultas (#{counts[:consultas]}), alertas (#{counts[:alertas]}) y salidas (#{counts[:checkouts]}).",
        "Elegí Pedidos, Consultas, Alertas o Checkouts para revisar una categoría.",
        owner_available_actions
      ].join("\n\n")
    end

    def normalized_typed_action
      normalize_command(@parsed.body)
    end

    def normalize_command(value)
      value.to_s.strip.downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
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
