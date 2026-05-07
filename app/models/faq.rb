class Faq < ApplicationRecord
  belongs_to :property

  validates :question, :answer, presence: true

  scope :active, -> { where(active: true) }
end
