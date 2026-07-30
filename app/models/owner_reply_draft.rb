class OwnerReplyDraft < ApplicationRecord
  STATUSES = %w[not_requested pending completed failed invalidated sent cancelled].freeze

  belongs_to :conversation
  belongs_to :user, optional: true
  belongs_to :co_host, optional: true

  validates :original_body, presence: true
  validates :translation_status, inclusion: { in: STATUSES }

  def invalidate_translation!(new_original)
    update!(
      original_body: new_original,
      translated_body: nil,
      translation_status: "invalidated",
      translation_provider: nil,
      translation_model: nil,
      error_message: nil
    )
  end
end
