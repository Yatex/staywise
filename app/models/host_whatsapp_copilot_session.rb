class HostWhatsappCopilotSession < ApplicationRecord
  STATES = %w[awaiting_property awaiting_guest_message active_thread].freeze
  ROLES = %w[owner co_host].freeze
  EXPIRATION = 24.hours

  belongs_to :account
  belongs_to :user
  belongs_to :co_host, optional: true
  belongs_to :selected_property, class_name: "Property", optional: true
  belongs_to :copilot_thread, optional: true

  validates :participant_phone, presence: true, uniqueness: true
  validates :actor_role, inclusion: { in: ROLES }
  validates :state, inclusion: { in: STATES }
  validates :last_activity_at, presence: true
  validate :tenant_consistency

  before_validation :normalize_phone

  scope :active, -> { where("last_activity_at >= ?", EXPIRATION.ago) }

  def expired?
    last_activity_at < EXPIRATION.ago
  end

  private

  def normalize_phone
    self.participant_phone = Whatsapp::HostActor.normalize(participant_phone)
  end

  def tenant_consistency
    errors.add(:user, "debe pertenecer a la cuenta") if user && user.account_id != account_id
    errors.add(:co_host, "debe pertenecer a la cuenta") if co_host && co_host.account_id != account_id
    if selected_property && selected_property.account_id != account_id
      errors.add(:selected_property, "debe pertenecer a la cuenta")
    end
    if copilot_thread && (
      copilot_thread.account_id != account_id ||
      copilot_thread.user_id != user_id ||
      (selected_property_id.present? && copilot_thread.property_id != selected_property_id)
    )
      errors.add(:copilot_thread, "no coincide con la sesión")
    end
  end
end
