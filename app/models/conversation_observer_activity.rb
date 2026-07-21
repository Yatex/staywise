class ConversationObserverActivity < ApplicationRecord
  NOTIFICATION_WINDOW = 5.minutes
  DIRECTIONS = %w[guest ai owner system].freeze

  belongs_to :account
  belongs_to :conversation
  belongs_to :property
  belongs_to :observer, polymorphic: true
  validates :last_activity_at, presence: true
  validates :latest_message_direction, inclusion: { in: DIRECTIONS }
  validates :unread_activity_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :conversation_id, uniqueness: { scope: [:observer_type, :observer_id] }

  scope :unseen, -> { where(observer_seen_at: nil).where("unread_activity_count > 0") }
  scope :recent_first, -> { order(last_activity_at: :desc, id: :desc) }

  def mark_seen!
    update!(observer_seen_at: Time.current, unread_activity_count: 0)
  end
end
