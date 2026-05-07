class OwnerAlertEmailJob < ApplicationJob
  queue_as :default

  def perform(alert_id)
    alert = Alert.includes(property: :account).find(alert_id)
    Notifications::OwnerAlertNotifier.call(alert)
  end
end
