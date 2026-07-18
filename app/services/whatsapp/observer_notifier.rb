module Whatsapp
  class ObserverNotifier
    Result = Struct.new(:sent?, :pending_conversations, :error, keyword_init: true)

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

      expire_observer_session!
      return result(error: "operational_session_active") if operational_session_active?
      return result(error: "observer_session_active") if observer_sessions.active.exists?

      activities = pending_activities.to_a
      return result(error: "nothing_pending") if activities.empty?
      return result(error: "observer_notice_recent") if notified_recently?
      return result(error: "operational_notice_recent") if operational_notice_recent?

      template_sid = ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
      return result(error: "observer_template_not_configured") if template_sid.blank?

      delivery = @provider.send_template(
        to: @actor.phone_number,
        template_sid: template_sid,
        variables: { "1" => activities.size.to_s }
      )
      unless delivery_success?(delivery)
        error = delivery_error(delivery)
        pending_activities.update_all(last_notification_error: error, updated_at: Time.current)
        ErrorReporter.report(source: "observer_notifier", severity: "error", account: @actor.account,
          message: "Observer WhatsApp notification failed",
          context: { recipient_type: @actor.type, recipient_id: @actor.id, recipient_phone: @actor.phone_number,
                     pending_conversations: activities.size, error: error })
        return result(error: error, count: activities.size)
      end

      notified_at = Time.current
      pending_activities.update_all(observer_notified_at: notified_at, last_notification_error: nil, updated_at: notified_at)
      Result.new(sent?: true, pending_conversations: activities.size, error: nil)
    rescue StandardError => error
      ErrorReporter.report(error, source: "observer_notifier", severity: "error", account: @actor.account,
        context: { recipient_type: @actor.type, recipient_id: @actor.id })
      result(error: error.message)
    end

    private

    def pending_activities
      ConversationObserverActivity
        .unseen
        .where(observer: @actor.observer, property_id: @actor.property_ids)
        .recent_first
    end

    def notified_recently?
      pending_activities.where("observer_notified_at >= ?", ConversationObserverActivity::NOTIFICATION_WINDOW.ago).exists?
    end

    def operational_notice_recent?
      participant_operational_sessions.where("last_prompted_at >= ?", ConversationObserverActivity::NOTIFICATION_WINDOW.ago).exists?
    end

    def operational_session_active?
      participant_operational_sessions.active.exists?
    end

    def participant_operational_sessions
      @actor.account.owner_whatsapp_sessions.where(participant_phone: @actor.phone_number)
    end

    def observer_sessions
      @actor.account.observer_whatsapp_sessions.where(participant_phone: @actor.phone_number)
    end

    def expire_observer_session!
      observer_sessions.active.where("expires_at <= ?", Time.current).find_each(&:resolve!)
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_error(delivery)
      delivery.respond_to?(:error) && delivery.error.present? ? delivery.error : "observer_whatsapp_delivery_failed"
    end

    def result(error:, count: nil)
      Result.new(sent?: false, pending_conversations: count || pending_activities.count, error: error)
    end
  end
end
