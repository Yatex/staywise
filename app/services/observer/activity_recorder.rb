module Observer
  class ActivityRecorder
    def self.call(message: nil, conversation: nil, direction: nil, provider: Whatsapp::ProviderFactory.build)
      conversation ||= message&.conversation
      direction ||= message&.sender || "system"
      return if conversation.blank?

      new(conversation: conversation, direction: direction, provider: provider).call
    end

    def initialize(conversation:, direction:, provider:)
      @conversation = conversation
      @property = conversation.property
      @direction = direction.to_s.in?(ConversationObserverActivity::DIRECTIONS) ? direction.to_s : "system"
      @provider = provider
    end

    def call
      Whatsapp::HostActor.for_property(@property).each do |actor|
        next unless actor.observer_mode_enabled?
        next unless actor.can_manage_property?(@property)
        next if actor.observer_mode_activated_at.present? && Time.current < actor.observer_mode_activated_at

        activity = record_for(actor)
        Whatsapp::ObserverNotifier.call(actor: actor, provider: @provider)
        activity
      rescue StandardError => error
        ErrorReporter.report(error, source: "observer_activity_recorder", severity: "error", account: actor.account,
          property: @property, context: { conversation_id: @conversation.id, recipient_type: actor.type, recipient_id: actor.id })
      end
    end

    private

    def record_for(actor)
      activity = ConversationObserverActivity.find_or_create_by!(
        observer: actor.observer,
        conversation: @conversation
      ) do |new_activity|
        new_activity.account = actor.account
        new_activity.property = @property
        new_activity.last_activity_at = Time.current
        new_activity.latest_message_direction = @direction
        new_activity.unread_activity_count = 0
      end
      activity.with_lock do
        activity.account = actor.account
        activity.property = @property
        activity.last_activity_at = Time.current
        activity.latest_message_direction = @direction
        activity.observer_seen_at = nil
        activity.unread_activity_count = activity.unread_activity_count.to_i + 1
        activity.last_notification_error = nil
        activity.save!
      end
      activity
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
