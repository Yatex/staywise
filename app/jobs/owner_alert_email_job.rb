class OwnerAlertEmailJob < ApplicationJob
  queue_as :default

  # Compatibility tombstone for jobs serialized before the Copilot migration.
  # Automatic operational notifications are not part of the Copilot runtime.
  def perform(_alert_id)
    Rails.logger.info("[owner-alert-email] ignored retired notification job")
  end
end
