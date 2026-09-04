class CopilotMessage < ApplicationRecord
  ROLES = %w[host assistant].freeze

  belongs_to :copilot_thread
  belongs_to :account
  belongs_to :property
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true
  validate :tenant_consistency

  private

  def tenant_consistency
    return unless copilot_thread

    errors.add(:account, "no coincide con el thread") if account_id != copilot_thread.account_id
    errors.add(:property, "no coincide con el thread") if property_id != copilot_thread.property_id
    errors.add(:user, "no coincide con el thread") if user_id != copilot_thread.user_id
  end
end
