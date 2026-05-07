class Recommendation < ApplicationRecord
  CATEGORIES = %w[restaurant cafe supermarket pharmacy attraction transport other].freeze

  belongs_to :property

  validates :name, presence: true
  validates :category, inclusion: { in: CATEGORIES }
end
