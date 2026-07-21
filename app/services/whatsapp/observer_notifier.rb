module Whatsapp
  class ObserverNotifier
    Result = Struct.new(:sent?, :pending_conversations, :error, :notification_url, keyword_init: true)
    RETRYABLE_ERRORS = %w[activity_window_open operational_session_active operational_notice_recent].freeze

    def self.call(actor:, provider: ProviderFactory.build)
      new(actor: actor, provider: provider).call
    end

    def initialize(actor:, provider:)
      @actor = actor
      @provider = provider
    end

    def call
      return result(error: "observer_mode_disabled") unless @actor.observer_mode_enabled?
      return result(error: "observer_whatsapp_not_configured") if @actor.phone_number.blank?

      @actor.observer.with_lock do
        activities = notifiable_activities.to_a
        return result(error: "nothing_pending", count: 0) if activities.empty?
        return result(error: "activity_window_open", count: activities.size) unless activity_window_closed?(activities)
        return result(error: "operational_session_active", count: activities.size) if operational_session_active?
        return result(error: "operational_notice_recent", count: activities.size) if operational_notice_recent?

        url = notification_url(activities)
        delivery = deliver_notification(activities, url)
        unless delivery_success?(delivery)
          error = delivery_error(delivery)
          mark_delivery_failure(activities, error)
          report_delivery_failure(activities, error)
          return result(error: error, count: activities.size, url: url)
        end

        notified_at = Time.current
        ConversationObserverActivity.where(id: activities.map(&:id)).update_all(
          observer_notified_at: notified_at,
          last_notification_error: nil,
          updated_at: notified_at
        )
        Result.new(sent?: true, pending_conversations: activities.size, error: nil, notification_url: url)
      end
    rescue StandardError => error
      ErrorReporter.report(error, source: "observer_notifier", severity: "error", account: @actor.account,
        context: { recipient_type: @actor.type, recipient_id: @actor.id })
      result(error: error.message)
    end

    private

    def notifiable_activities
      ConversationObserverActivity
        .unseen
        .where(observer: @actor.observer, property_id: @actor.property_ids)
        .where("observer_notified_at IS NULL OR observer_notified_at < last_activity_at")
        .includes(:property, conversation: :guest)
        .recent_first
    end

    def activity_window_closed?(activities)
      activities.map(&:last_activity_at).compact.max <= ConversationObserverActivity::NOTIFICATION_WINDOW.ago
    end

    def operational_session_active?
      participant_operational_sessions.active
        .where("expires_at IS NULL OR expires_at > ?", Time.current)
        .exists?
    end

    def operational_notice_recent?
      participant_operational_sessions
        .where("last_prompted_at >= ?", ConversationObserverActivity::NOTIFICATION_WINDOW.ago)
        .exists?
    end

    def participant_operational_sessions
      @actor.account.owner_whatsapp_sessions.where(participant_phone: @actor.phone_number)
    end

    def deliver_notification(activities, url)
      template_sid = ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
      if template_sid.present?
        @provider.send_template(
          to: @actor.phone_number,
          template_sid: template_sid,
          variables: { "1" => notification_summary(activities), "2" => url }
        )
      else
        @provider.send_message(to: @actor.phone_number, body: notification_body(activities, url))
      end
    end

    def notification_summary(activities)
      return "Hay actividad en #{activities.size} conversaciones." if activities.many?

      activity = activities.first
      guest = activity.conversation.guest
      guest_name = guest&.name.presence || guest&.phone_number.presence || "Huésped de WhatsApp"
      "Hay actividad nueva en una conversación.\n\nHuésped: #{guest_name}\nPropiedad: #{activity.property.display_name}"
    end

    def notification_body(activities, url)
      link_label = activities.one? ? "Abrir conversación:" : "Ver conversaciones:"
      "#{notification_summary(activities)}\n\n#{link_label}\n#{url}"
    end

    def notification_url(activities)
      routes = Rails.application.routes.url_helpers
      options = { host: ENV["APP_HOST"].presence || "http://localhost:3000" }
      return routes.conversation_url(activities.first.conversation, **options) if activities.one?

      routes.conversations_url(**options.merge(filter: "unread"))
    end

    def mark_delivery_failure(activities, error)
      ConversationObserverActivity.where(id: activities.map(&:id)).update_all(
        last_notification_error: error,
        updated_at: Time.current
      )
    end

    def report_delivery_failure(activities, error)
      ErrorReporter.report(source: "observer_notifier", severity: "error", account: @actor.account,
        message: "Observer WhatsApp notification failed",
        context: { recipient_type: @actor.type, recipient_id: @actor.id, recipient_phone: @actor.phone_number,
                   pending_conversations: activities.size, error: error })
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_error(delivery)
      delivery.respond_to?(:error) && delivery.error.present? ? delivery.error : "observer_whatsapp_delivery_failed"
    end

    def result(error:, count: nil, url: nil)
      Result.new(
        sent?: false,
        pending_conversations: count.nil? ? notifiable_activities.count : count,
        error: error,
        notification_url: url
      )
    end
  end
end
