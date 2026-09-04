class CopilotThread < ApplicationRecord
  STATUSES = %w[active archived].freeze
  SOURCES = %w[web whatsapp].freeze

  belongs_to :account
  belongs_to :property
  belongs_to :user
  has_many :copilot_messages, dependent: :destroy
  has_many :copilot_runs, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validate :tenant_consistency

  scope :recent, -> { order(last_message_at: :desc, created_at: :desc) }

  def display_title
    title.presence || "Consulta sobre #{property.display_name}"
  end

  private

  def tenant_consistency
    errors.add(:property, "debe pertenecer a la cuenta") if property && property.account_id != account_id
    errors.add(:user, "debe pertenecer a la cuenta") if user && user.account_id != account_id
  end
end
