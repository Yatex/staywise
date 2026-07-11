class OwnerTask < ApplicationRecord
  self.table_name = "guest_requests"

  KINDS = %w[request inquiry].freeze
  CATEGORIES = %w[food_or_drink extra_bed extra_item service transport late_checkout early_checkin reservation_change other].freeze
  STATUSES = %w[pending in_progress resolved rejected cancelled].freeze
  PRIORITIES = %w[normal high].freeze
  APPROVAL_CATEGORIES = %w[late_checkout early_checkin reservation_change].freeze

  belongs_to :account
  belongs_to :property
  belongs_to :conversation
  belongs_to :guest
  belongs_to :message
  belongs_to :ai_decision_log, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :guest_phone, :property_name, :title, :description, :source_channel, presence: true

  scope :requests, -> { where(kind: "request") }
  scope :inquiries, -> { where(kind: "inquiry") }
  scope :pending_first, -> { order(Arel.sql("CASE status WHEN 'pending' THEN 0 WHEN 'in_progress' THEN 1 ELSE 2 END"), created_at: :desc) }
  scope :open, -> { where(status: %w[pending in_progress]) }

  before_save :set_resolved_at

  def requires_owner_approval?
    self[:requires_owner_approval] || category.in?(APPROVAL_CATEGORIES)
  end

  private

  def set_resolved_at
    self.resolved_at = Time.current if status.in?(%w[resolved rejected cancelled]) && resolved_at.blank?
    self.resolved_at = nil if status.in?(%w[pending in_progress])
  end
end
