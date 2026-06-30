class OperationalError < ApplicationRecord
  SEVERITIES = %w[info warning error critical].freeze

  belongs_to :account, optional: true
  belongs_to :property, optional: true

  validates :source, :message, presence: true
  validates :severity, inclusion: { in: SEVERITIES }

  scope :recent, -> { order(created_at: :desc) }
  scope :open, -> { where(resolved_at: nil) }
  scope :resolved, -> { where.not(resolved_at: nil) }

  def resolved?
    resolved_at.present?
  end
end
