class Property < ApplicationRecord
  attribute :ai_enabled, :boolean, default: true

  STATUSES = %w[active archived].freeze
  COPYABLE_SETTING_ATTRIBUTES = %w[
    check_in_time
    checkout_time
    checkout_instructions
    wifi_name
    wifi_password
    house_rules
    access_instructions
    parking_instructions
    emergency_information
    owner_contact_instructions
    ai_general_notes
    ai_enabled
    tags
  ].freeze

  belongs_to :account
  has_many :knowledge_blocks, dependent: :destroy
  has_many :recommendations, dependent: :destroy
  has_many :sensitive_data, class_name: "PropertySensitiveDatum", dependent: :destroy
  has_many :faqs, dependent: :destroy
  has_many :guests, dependent: :nullify
  has_many :conversations, dependent: :destroy
  has_many :alerts, dependent: :destroy
  has_many :owner_tasks, dependent: :destroy
  has_many :guest_requests, -> { requests }, class_name: "OwnerTask"
  has_many :operational_errors, dependent: :nullify

  validates :name, presence: true
  validates :public_token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validate :account_property_limit, on: :create

  has_secure_token :public_token

  before_validation :normalize_tags

  default_scope { where(deleted_at: nil) }

  scope :with_deleted, -> { unscope(where: :deleted_at) }
  scope :deleted, -> { with_deleted.where.not(deleted_at: nil) }
  scope :active, -> { where(status: "active") }
  scope :tagged_with, ->(tag) { where("? = ANY(tags)", tag.to_s.downcase) }

  def display_name
    internal_nickname.presence || name
  end

  def tag_list
    tags.join(", ")
  end

  def tag_list=(value)
    self.tags = value.to_s.split(",").map { |tag| tag.strip.downcase }.compact_blank.uniq
  end

  def copyable_settings
    attributes.slice(*COPYABLE_SETTING_ATTRIBUTES)
  end

  def whatsapp_reference
    "Ayla stay #{public_token}"
  end

  def deleted?
    deleted_at.present?
  end

  def soft_delete
    soft_delete!
    self
  rescue ActiveRecord::RecordInvalid
    false
  end

  def soft_delete!
    return true if deleted?

    update!(deleted_at: Time.current)
  end

  def destroy
    soft_delete
  end

  def destroy!
    soft_delete!
    self
  end

  def delete
    soft_delete
  end

  private

  def normalize_tags
    self.tags = Array(tags).map { |tag| tag.to_s.strip.downcase }.compact_blank.uniq
  end

  def account_property_limit
    return if account.blank? || account.can_add_property?

    errors.add(:base, "Your current plan does not allow another property.")
  end
end
