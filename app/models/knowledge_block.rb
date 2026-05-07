class KnowledgeBlock < ApplicationRecord
  CATEGORIES = %w[
    check_in
    checkout
    wifi
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

  scope :active, -> { where(status: "active") }
end
