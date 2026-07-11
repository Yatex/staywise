class OwnerTask < ApplicationRecord
  self.table_name = "guest_requests"

  KINDS = %w[request inquiry].freeze
  CATEGORIES = %w[food_or_drink extra_bed extra_item service transport late_checkout early_checkin reservation_change other].freeze
  STATUSES = %w[open resolved].freeze
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
  validates :guest_phone, :property_name, :title, :description, :source_channel, presence: true

  scope :requests, -> { where(kind: "request") }
  scope :inquiries, -> { where(kind: "inquiry") }
  scope :pending_first, -> { order(Arel.sql("CASE status WHEN 'open' THEN 0 ELSE 1 END"), created_at: :desc) }
  scope :open, -> { where(status: "open") }

  before_save :set_resolved_at

  def requires_owner_approval?
    self[:requires_owner_approval] || category.in?(APPROVAL_CATEGORIES)
  end

  private

  def set_resolved_at
    self.resolved_at = Time.current if status == "resolved" && resolved_at.blank?
    self.resolved_at = nil if status == "open"
  end
end
