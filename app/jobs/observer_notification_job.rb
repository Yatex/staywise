class ObserverNotificationJob < ApplicationJob
  queue_as :default

  # Kept temporarily so jobs enqueued before the Copilot migration deserialize
  # safely. Observer Mode is retired and this job intentionally has no effects.
  def perform(_observer_type, _observer_id)
    Rails.logger.info("[observer] ignored retired notification job")
  end
end
