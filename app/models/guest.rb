class Guest < ApplicationRecord
  belongs_to :account
  belongs_to :property, optional: true
  has_many :conversations, dependent: :destroy
  has_many :alerts, dependent: :nullify
  has_many :owner_tasks, dependent: :destroy
  has_many :guest_requests, -> { requests }, class_name: "OwnerTask"
  has_many :checkout_events, dependent: :destroy

  validates :phone_number, presence: true, uniqueness: { scope: :account_id }

  before_validation :normalize_phone_number

  def display_name
    name.presence || phone_number
  end

  private

  def normalize_phone_number
    self.phone_number = phone_number.to_s.gsub(/\Awhatsapp:/, "").strip
  end
end
