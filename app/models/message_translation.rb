class MessageTranslation < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze
  TARGET_LANGUAGES = %w[es en].freeze

  belongs_to :message

  validates :target_language, inclusion: { in: TARGET_LANGUAGES }
  validates :status, inclusion: { in: STATUSES }
  validates :target_language, uniqueness: { scope: :message_id }
  validates :translated_body, presence: true, if: :completed?

  scope :completed, -> { where(status: "completed") }

  def completed?
    status == "completed"
  end
end
