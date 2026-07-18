class Conversation < ApplicationRecord
  STATUSES = %w[active escalated closed].freeze
  CHANNELS = %w[whatsapp].freeze

  belongs_to :guest
  belongs_to :property
  has_many :checkout_events, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :alerts, dependent: :nullify
  has_many :owner_tasks, dependent: :destroy
  has_many :conversation_observer_activities, dependent: :destroy
  has_many :guest_requests, -> { requests }, class_name: "OwnerTask"

  validates :status, inclusion: { in: STATUSES }
  validates :channel, inclusion: { in: CHANNELS }
  validates :channel_participant, presence: true, uniqueness: { scope: :channel }

  before_validation :set_channel_participant
  after_update_commit :record_observable_status_change, if: :saved_change_to_status?

  scope :recent, -> { order(last_message_at: :desc, updated_at: :desc) }
  scope :open, -> { where(status: %w[active escalated]) }

  def mark_message_received!
    touch(:last_message_at)
  end

  private

  def set_channel_participant
    self.channel ||= "whatsapp"
    self.channel_participant = guest&.phone_number if channel_participant.blank?
  end

  def record_observable_status_change
    Observer::ActivityRecorder.call(conversation: self, direction: "system")
  rescue StandardError => error
    ErrorReporter.report(error, source: "observer_activity_recorder", severity: "error", account: property&.account,
      property: property, context: { conversation_id: id, event: "status_change" })
  end
end
