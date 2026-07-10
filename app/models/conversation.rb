class Conversation < ApplicationRecord
  STATUSES = %w[active escalated closed].freeze
  CHANNELS = %w[whatsapp].freeze

  belongs_to :guest
  belongs_to :property
  has_many :messages, dependent: :destroy
  has_many :alerts, dependent: :nullify
  has_many :guest_requests, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :channel, inclusion: { in: CHANNELS }
  validates :channel_participant, presence: true, uniqueness: { scope: :channel }

  before_validation :set_channel_participant

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
end
