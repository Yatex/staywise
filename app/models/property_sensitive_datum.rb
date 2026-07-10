class PropertySensitiveDatum < ApplicationRecord
  KINDS = %w[
    safe_code
    lockbox_code
    door_code
    gate_code
    alarm_code
    building_access_code
    key_location
    device_password
  ].freeze

  belongs_to :property
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :source_alert, class_name: "Alert", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :encrypted_value, presence: true

  scope :active, -> { where(active: true) }

  def value
    self.class.encryptor.decrypt_and_verify(encrypted_value)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def value=(plain_value)
    self.encrypted_value = self.class.encryptor.encrypt_and_sign(plain_value.to_s)
  end

  def self.encryptor
    key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key("property-sensitive-data", 32)
    ActiveSupport::MessageEncryptor.new(key)
  end
end
