class Message < ApplicationRecord
  SENDERS = %w[guest ai owner system].freeze
  CHANNELS = %w[whatsapp dashboard].freeze

  belongs_to :conversation
  belongs_to :account, optional: true
  belongs_to :property, optional: true
  has_one :checkout_event, foreign_key: :source_message_id, dependent: :restrict_with_exception
  has_many :message_translations, dependent: :destroy

  validates :sender, inclusion: { in: SENDERS }
  validates :channel, inclusion: { in: CHANNELS }
  validates :body, presence: true

  before_validation :set_tenant_from_conversation
  after_create_commit :update_conversation_timestamp

  def translation_for(language)
    normalized = AI::LanguageHelper.normalize_code(language)
    message_translations.find { |translation| translation.target_language == normalized && translation.completed? }
  end

  private

  def set_tenant_from_conversation
    return if conversation.blank?

    self.property_id ||= conversation.property_id
    self.account_id ||= conversation.property&.account_id
  end

  def update_conversation_timestamp
    conversation.mark_message_received!
  end

end
