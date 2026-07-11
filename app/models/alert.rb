class Alert < ApplicationRecord
  TYPES = %w[
    late_checkout_request
    missing_item
    maintenance_issue
    emergency
    complaint
    owner_approval_required
    missing_sensitive_information
    unknown_question
    other
  ].freeze
  STATUSES = %w[open resolved].freeze

  belongs_to :property
  belongs_to :guest, optional: true
  belongs_to :conversation, optional: true
  belongs_to :original_message, class_name: "Message", optional: true
  belongs_to :ai_decision_log, optional: true

  validates :alert_type, inclusion: { in: TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :title, presence: true

  scope :open, -> { where(status: "open") }
  scope :urgent, -> { where(priority: "urgent") }
  scope :unknown_questions, -> { where(alert_type: "unknown_question") }
  scope :operational, -> { where.not(alert_type: "unknown_question") }

  before_save :set_resolved_at

  private

  def set_resolved_at
    self.resolved_at = Time.current if status == "resolved" && resolved_at.blank?
    self.resolved_at = nil if status == "open"
  end
end
