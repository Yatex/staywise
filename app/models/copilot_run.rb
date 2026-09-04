class CopilotRun < ApplicationRecord
  STATUSES = %w[pending completed failed].freeze

  belongs_to :copilot_thread
  belongs_to :copilot_message
  belongs_to :account
  belongs_to :property
  belongs_to :user
  has_one :ai_decision_log, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :confidence, numericality: { only_integer: true, in: 0..100 }, allow_nil: true
  validate :tenant_consistency
  validate :completed_contract

  private

  def tenant_consistency
    return unless copilot_thread

    errors.add(:account, "no coincide con el thread") if account_id != copilot_thread.account_id
    errors.add(:property, "no coincide con el thread") if property_id != copilot_thread.property_id
    errors.add(:user, "no coincide con el thread") if user_id != copilot_thread.user_id
    errors.add(:copilot_message, "no pertenece al thread") if copilot_message && copilot_message.copilot_thread_id != copilot_thread_id
  end

  def completed_contract
    return unless status == "completed"

    %i[detected_language guest_question_es answer_summary_es confidence].each do |field|
      errors.add(field, "es obligatorio") if public_send(field).blank?
    end
    if missing_information?
      errors.add(:clarifying_question_es, "es obligatoria cuando falta información") if clarifying_question_es.blank?
    else
      errors.add(:guest_reply, "es obligatoria") if guest_reply.blank?
    end
  end
end
