class CoHost < ApplicationRecord
  belongs_to :account
  has_many :properties, dependent: :nullify
  has_many :owner_whatsapp_sessions, dependent: :nullify
  has_many :conversation_observer_activities, as: :observer, dependent: :destroy
  has_many :owner_reply_drafts, dependent: :nullify
  has_many :host_whatsapp_copilot_sessions, dependent: :destroy

  validates :name, :whatsapp_number, presence: true
  validates :whatsapp_number, uniqueness: true
  validates :preferred_conversation_language, inclusion: { in: User::CONVERSATION_LANGUAGES }
  validates :whatsapp_number, format: { with: /\A\+\d{8,15}\z/, message: "debe incluir código de país, por ejemplo +598..." }
  validate :phone_is_not_an_owner_phone

  before_validation :normalize_whatsapp_number

  private

  def normalize_whatsapp_number
    self.whatsapp_number = whatsapp_number.to_s.gsub(/\Awhatsapp:/, "").gsub(/[^\d+]/, "").strip.presence
  end

  def phone_is_not_an_owner_phone
    return if whatsapp_number.blank?
    return unless Account.where(owner_whatsapp_number: whatsapp_number).exists?

    errors.add(:whatsapp_number, "ya pertenece a un anfitrión principal")
  end

end
