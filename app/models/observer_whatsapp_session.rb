class ObserverWhatsappSession < ApplicationRecord
  STATES = %w[active resolved].freeze

  belongs_to :account
  belongs_to :co_host, optional: true
  belongs_to :current_activity, class_name: "ConversationObserverActivity", optional: true

  validates :participant_phone, presence: true
  validates :actor_role, inclusion: { in: %w[owner co_host] }
  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: "active") }

  def active?
    state == "active"
  end

  def resolve!
    update!(state: "resolved", resolved_at: Time.current, current_activity: nil)
  end
end
