class CheckoutEvent < ApplicationRecord
  STATUSES = %w[pending seen].freeze

  belongs_to :account
  belongs_to :property
  belongs_to :guest
  belongs_to :conversation
  belongs_to :source_message, class_name: "Message"

  validates :guest_message_body, :checked_out_at, :reservation_key, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :reservation_key, uniqueness: { scope: :account_id }
  validates :source_message_id, uniqueness: true
  validates :provider_message_sid, uniqueness: true, allow_blank: true
  validate :tenant_consistency

  scope :pending, -> { where(status: "pending", owner_seen_at: nil) }

  def pending?
    status == "pending" && owner_seen_at.nil?
  end

  def mark_seen!
    with_lock do
      update!(status: "seen", owner_seen_at: owner_seen_at || Time.current)
    end
  end

  private

  def tenant_consistency
    return if account.blank? || property.blank? || guest.blank? || conversation.blank? || source_message.blank?

    errors.add(:property, "does not belong to account") unless property.account_id == account_id
    errors.add(:guest, "does not belong to account") unless guest.account_id == account_id
    errors.add(:conversation, "does not match property and guest") unless conversation.property_id == property_id && conversation.guest_id == guest_id
    errors.add(:source_message, "does not belong to conversation") unless source_message.conversation_id == conversation_id
  end
end
