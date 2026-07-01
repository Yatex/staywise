class User < ApplicationRecord
  ROLES = %w[owner admin member].freeze

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

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
