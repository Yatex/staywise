class Subscription < ApplicationRecord
  PLANS = %w[starter growth pro business].freeze
  STATUSES = %w[trialing active past_due canceled incomplete].freeze
  PLAN_LIMITS = {
    "starter" => 3,
    "growth" => 10,
    "pro" => 25,
    "business" => 50
  }.freeze

  belongs_to :account

  validates :plan, inclusion: { in: PLANS }
  validates :status, inclusion: { in: STATUSES }

  def property_limit
    PLAN_LIMITS.fetch(plan)
  end

  def active?
    status.in?(%w[trialing active])
  end
end
