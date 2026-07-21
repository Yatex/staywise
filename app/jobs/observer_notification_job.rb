class ObserverNotificationJob < ApplicationJob
  queue_as :default

  def perform(observer_type, observer_id)
    actor = resolve_actor(observer_type, observer_id)
    return unless actor

    result = Whatsapp::ObserverNotifier.call(actor: actor)
    if result.error.in?(Whatsapp::ObserverNotifier::RETRYABLE_ERRORS)
      self.class.set(wait: ConversationObserverActivity::NOTIFICATION_WINDOW).perform_later(observer_type, observer_id)
    end
  end

  private

  def resolve_actor(observer_type, observer_id)
    case observer_type
    when "Account"
      account = Account.find_by(id: observer_id)
      Whatsapp::HostActor.owner(account) if account
    when "CoHost"
      co_host = CoHost.find_by(id: observer_id)
      Whatsapp::HostActor.co_host(co_host) if co_host
    end
  end
end
