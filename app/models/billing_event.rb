class BillingEvent < ApplicationRecord
  belongs_to :account, optional: true

  validates :stripe_event_id, :event_type, presence: true
  validates :stripe_event_id, uniqueness: true
end
