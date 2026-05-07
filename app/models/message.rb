class Message < ApplicationRecord
  SENDERS = %w[guest ai owner system].freeze
  CHANNELS = %w[whatsapp dashboard].freeze

  belongs_to :conversation

  validates :sender, inclusion: { in: SENDERS }
  validates :channel, inclusion: { in: CHANNELS }
  validates :body, presence: true

  after_create_commit :update_conversation_timestamp

  private

  def update_conversation_timestamp
    conversation.mark_message_received!
  end
end
