class CoHost < ApplicationRecord
  belongs_to :account
  has_many :properties, dependent: :nullify
  has_many :owner_whatsapp_sessions, dependent: :nullify
  has_many :observer_whatsapp_sessions, dependent: :nullify
  has_many :conversation_observer_activities, as: :observer, dependent: :destroy

  validates :name, :whatsapp_number, presence: true
  validates :whatsapp_number, uniqueness: true
  validates :whatsapp_number, format: { with: /\A\+\d{8,15}\z/, message: "debe incluir código de país, por ejemplo +598..." }
  validate :phone_is_not_an_owner_phone

  before_validation :normalize_whatsapp_number
  before_save :stamp_observer_mode_activation
  after_update :close_observer_mode_if_disabled

  private

  def normalize_whatsapp_number
    self.whatsapp_number = whatsapp_number.to_s.gsub(/\Awhatsapp:/, "").gsub(/[^\d+]/, "").strip.presence
  end

  def phone_is_not_an_owner_phone
    return if whatsapp_number.blank?
    return unless Account.where(owner_whatsapp_number: whatsapp_number).exists?

    errors.add(:whatsapp_number, "ya pertenece a un anfitrión principal")
  end

  def stamp_observer_mode_activation
    return unless will_save_change_to_observer_mode_enabled?

    self.observer_mode_activated_at = observer_mode_enabled? ? Time.current : nil
  end

  def close_observer_mode_if_disabled
    return unless saved_change_to_observer_mode_enabled? && !observer_mode_enabled?

    conversation_observer_activities.unseen.update_all(observer_seen_at: Time.current, unread_activity_count: 0, updated_at: Time.current)
    observer_whatsapp_sessions.active.update_all(state: "resolved", resolved_at: Time.current, current_activity_id: nil, updated_at: Time.current)
  end
end
