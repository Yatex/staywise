class User < ApplicationRecord
  ROLES = %w[owner admin member].freeze
  TERMS_VERSION = "2026-07-01".freeze
  PRIVACY_VERSION = "2026-07-01".freeze

  belongs_to :account

  has_secure_password
  has_secure_token :email_verification_token

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 8 }, allow_nil: true

  before_validation :normalize_email

  def admin?
    role == "admin"
  end

  def owner?
    role == "owner"
  end

  def member?
    role == "member"
  end

  def admin_like?
    admin?
  end

  def email_verified?
    email_verified_at.present?
  end

  def email_verification_required?
    !email_verified?
  end

  def verify_email!
    update!(
      email_verified_at: Time.current,
      email_verification_token: nil,
      email_verification_sent_at: nil
    )
  end

  def accept_legal_documents!(request:)
    self.terms_accepted_at = Time.current
    self.privacy_accepted_at = Time.current
    self.terms_version = TERMS_VERSION
    self.privacy_version = PRIVACY_VERSION
    self.legal_acceptance_ip = request.remote_ip
    self.legal_acceptance_user_agent = request.user_agent.to_s.truncate(1_000)
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
