class Faq < ApplicationRecord
  STATUSES = %w[pending_review approved archived].freeze
  SOURCE_TYPES = %w[manual owner_answer ai_import copied].freeze

  belongs_to :property
  belongs_to :source_alert, class_name: "Alert", optional: true
  belongs_to :source_message, class_name: "Message", optional: true

  validates :question, :answer, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  scope :active, -> { where(active: true, status: "approved") }
  scope :pending_review, -> { where(status: "pending_review") }
end
