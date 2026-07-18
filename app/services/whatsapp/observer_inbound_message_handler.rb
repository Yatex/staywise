module Whatsapp
  class ObserverInboundMessageHandler
    ACTION_IDS = %w[conversaciones ver_conversacion siguiente conversacion_vista salir].freeze
    SESSION_ACTION_IDS = %w[ver_conversacion siguiente conversacion_vista salir].freeze
    SESSION_DURATION = 30.minutes

    def initialize(parsed, provider: ProviderFactory.build)
      @parsed = parsed
      @provider = provider
      @actor = HostActor.resolve(parsed.from)
      @account = @actor.account
    end

    def handle?
      action_id == "conversaciones" || active_session.present?
    end

    def call
      @account.with_lock do
        session = active_session
        return handled(session, duplicate: true) if session && duplicate_webhook?(session)

        if session
          remember_webhook!(session)
          return handle_session(session)
        end

        return handled(nil, replied: send_owner_message("El Modo observador está desactivado.")) unless @actor.observer_mode_enabled?
        if operational_session_active?
          return handled(nil, replied: send_owner_message("Terminá primero la revisión operativa actual. Las conversaciones con novedades quedan guardadas."))
        end

        start_session
      end
    end

    private

    def start_session
      activity = pending_activities.first
      return handled(nil, replied: send_owner_message("No tenés conversaciones con novedades.")) unless activity

      session = observer_sessions.create!(
        co_host: @actor.co_host,
        participant_phone: @actor.phone_number,
        actor_role: @actor.role,
        state: "active",
        current_activity: activity,
        started_at: Time.current,
        expires_at: SESSION_DURATION.from_now
      )
      remember_webhook!(session)
      show_current(session)
    rescue ActiveRecord::RecordNotUnique
      session = observer_sessions.active.first
      show_current(session)
    end

    def handle_session(session)
      case action_id
      when "ver_conversacion"
        activity = validated_activity(session)
        return advance_or_finish(session) unless activity

        send_owner_message("Abrí la conversación completa en Ayla:\n#{conversation_url(activity.conversation)}")
        send_actions
        handled(session)
      when "siguiente"
        show_next(session)
      when "conversacion_vista"
        activity = validated_activity(session)
        return advance_or_finish(session) unless activity

        activity.mark_seen!
        advance_or_finish(session)
      when "salir"
        finish_session(session)
      else
        send_owner_message("Abrí la conversación en Ayla para intervenir o elegí una de las opciones.")
        send_actions
        handled(session)
      end
    end

    def show_current(session)
      activity = validated_activity(session)
      return advance_or_finish(session) unless activity

      session.update!(last_prompted_at: Time.current, expires_at: SESSION_DURATION.from_now)
      send_owner_message(activity_detail(activity))
      send_actions
      handled(session, selected: true)
    end

    def show_next(session)
      activities = pending_activities.to_a
      return finish_session(session) if activities.empty?

      current_index = activities.index { |activity| activity.id == session.current_activity_id }
      next_activity = current_index ? activities[(current_index + 1) % activities.length] : activities.first
      session.update!(current_activity: next_activity, expires_at: SESSION_DURATION.from_now)
      show_current(session)
    end

    def advance_or_finish(session)
      next_activity = pending_activities.where.not(id: session.current_activity_id).first || pending_activities.first
      return finish_session(session) unless next_activity

      session.update!(current_activity: next_activity, expires_at: SESSION_DURATION.from_now)
      show_current(session)
    end

    def activity_detail(activity)
      activities = pending_activities.to_a
      position = activities.index { |candidate| candidate.id == activity.id }.to_i + 1
      conversation = activity.conversation
      guest = conversation.guest
      last_guest = conversation.messages.where(sender: "guest").order(created_at: :desc, id: :desc).first
      last_ai = conversation.messages.where(sender: "ai").order(created_at: :desc, id: :desc).first
      guest_label = [guest&.name.presence, guest&.phone_number.presence].compact.join(" · ").presence || "Huésped de WhatsApp"

      sections = [
        "Conversación #{position} de #{activities.size}",
        "Propiedad:\n#{activity.property.display_name}",
        "Huésped:\n#{guest_label}",
        "Última actividad:\n#{activity_label(activity)}",
        "Último mensaje:\n“#{last_guest&.body.to_s.squish.presence || 'Sin mensaje del huésped'}”"
      ]
      sections << "Ayla respondió:\n“#{last_ai.body.to_s.squish}”" if last_ai.present?
      sections << "Nuevos mensajes:\n#{activity.unread_activity_count}"
      sections << "Abrí la conversación completa en Ayla para supervisarla o intervenir."
      sections.join("\n\n").truncate(3_500)
    end

    def activity_label(activity)
      actor = {
        "guest" => "El huésped escribió",
        "ai" => "Ayla respondió",
        "owner" => "El anfitrión respondió",
        "system" => "Cambió el estado de la conversación"
      }.fetch(activity.latest_message_direction)
      "#{actor} #{helpers.time_ago_in_words(activity.last_activity_at)} atrás."
    end

    def send_actions
      @provider.send_interactive(
        to: @actor.phone_number,
        content_key: :observer_actions,
        fallback_body: "Opciones: ver_conversacion, siguiente, conversacion_vista o salir."
      )
    end

    def finish_session(session)
      session.resolve!
      send_owner_message("Sesión observadora finalizada.")
      operational = OwnerEscalationNotifier.call(actor: @actor, provider: @provider, allow_after_observer: true)
      ObserverNotifier.call(actor: @actor, provider: @provider) unless operational.sent?
      handled(session, finished: true)
    end

    def pending_activities
      ConversationObserverActivity.unseen
        .where(observer: @actor.observer, property_id: @actor.property_ids)
        .includes(:property, conversation: [:guest, :messages])
        .recent_first
    end

    def validated_activity(session)
      activity = pending_activities.find_by(id: session.current_activity_id)
      return unless activity
      return unless @actor.can_manage_property?(activity.property)
      return unless activity.conversation.property_id == activity.property_id

      activity
    end

    def active_session
      session = observer_sessions.active.order(created_at: :desc).first
      return session unless session&.expires_at&.<=(Time.current)

      session.resolve!
      nil
    end

    def operational_session_active?
      @account.owner_whatsapp_sessions.active.exists?(participant_phone: @actor.phone_number)
    end

    def observer_sessions
      @account.observer_whatsapp_sessions.where(participant_phone: @actor.phone_number)
    end

    def duplicate_webhook?(session)
      message_sid.present? && Array(session.processed_message_sids).include?(message_sid)
    end

    def remember_webhook!(session)
      return if message_sid.blank?

      session.update!(processed_message_sids: (Array(session.processed_message_sids) + [message_sid]).last(100))
    end

    def action_id
      interactive = @parsed.interactive_action_id.to_s.strip.downcase
      return interactive if ACTION_IDS.include?(interactive)

      typed = @parsed.body.to_s.strip.downcase
      allowed = active_session.present? ? SESSION_ACTION_IDS : ["conversaciones"]
      allowed.include?(typed) ? typed : nil
    end

    def message_sid
      @parsed.metadata.to_h["MessageSid"].presence || @parsed.metadata.to_h["SmsMessageSid"].presence
    end

    def conversation_url(conversation)
      Rails.application.routes.url_helpers.conversation_url(
        conversation,
        host: ENV["APP_HOST"].presence || "http://localhost:3000"
      )
    end

    def send_owner_message(body)
      delivery = @provider.send_message(to: @actor.phone_number, body: body)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def helpers
      ActionController::Base.helpers
    end

    def handled(session, extras = {})
      { owner_message: true, handled: true, session: session, replied: true }.merge(extras)
    end
  end
end
