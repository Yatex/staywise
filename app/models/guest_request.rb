class GuestRequest < ApplicationRecord
  CATEGORIES = %w[
    food_or_drink
    extra_bed
    extra_item
    service
    transport
    late_checkout
    early_checkin
    reservation_change
    other
  ].freeze
  STATUSES = %w[pending in_progress resolved rejected cancelled].freeze
  PRIORITIES = %w[normal high].freeze

  belongs_to :account
  belongs_to :property
  belongs_to :conversation
  belongs_to :guest
  belongs_to :message
  belongs_to :ai_decision_log, optional: true

  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :guest_phone, :property_name, :title, :description, :source_channel, presence: true

  scope :pending_first, -> { order(Arel.sql("CASE status WHEN 'pending' THEN 0 WHEN 'in_progress' THEN 1 ELSE 2 END"), created_at: :desc) }
  scope :open, -> { where(status: %w[pending in_progress]) }

  before_save :set_resolved_at

  private

  def set_resolved_at
    self.resolved_at = Time.current if status.in?(%w[resolved rejected cancelled]) && resolved_at.blank?
    self.resolved_at = nil if status.in?(%w[pending in_progress])
  end
end
