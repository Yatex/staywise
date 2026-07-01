class KnowledgeBlock < ApplicationRecord
  CATEGORIES = %w[
    check_in
    checkout
    wifi
    appliances
    house_rules
    amenities
    building_access
    transportation
    emergencies
    custom_notes
  ].freeze
  STATUSES = %w[active inactive draft].freeze

  belongs_to :property

  validates :title, :content, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :youtube_url, format: { with: /\Ahttps?:\/\/(www\.)?(youtube\.com|youtu\.be)\//i, message: "debe ser un link de YouTube válido" }, allow_blank: true

  scope :active, -> { where(status: "active") }
end
