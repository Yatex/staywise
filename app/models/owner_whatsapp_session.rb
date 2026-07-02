class OwnerWhatsappSession < ApplicationRecord
  STATES = %w[queued awaiting_ack awaiting_answer on_hold resolved failed].freeze
  ACTIVE_STATES = %w[awaiting_ack awaiting_answer].freeze

  belongs_to :account
  belongs_to :alert

  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :pending, -> { where(state: %w[queued on_hold]) }
  scope :unresolved, -> { where.not(state: %w[resolved failed]) }

  def active?
    state.in?(ACTIVE_STATES)
  end
end
