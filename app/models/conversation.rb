class Conversation < ApplicationRecord
  STATUSES = %w[active escalated closed].freeze

  belongs_to :guest
  belongs_to :property
  has_many :messages, dependent: :destroy
  has_many :alerts, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(last_message_at: :desc, updated_at: :desc) }
  scope :open, -> { where(status: %w[active escalated]) }

  def mark_message_received!
    touch(:last_message_at)
  end
end
