class Account < ApplicationRecord
  AI_RESPONSE_STYLES = %w[concise warm detailed].freeze
  AI_CHANNELS = %w[whatsapp].freeze
  AI_LANGUAGES = %w[en es].freeze
  DEFAULT_ESCALATION_RULES = {
    "late_checkout_request" => true,
    "missing_item" => true,
    "maintenance_issue" => true,
    "emergency" => true,
    "complaint" => true,
    "owner_approval_required" => true,
    "unknown_question" => true
  }.freeze
  DEFAULT_AUTOMATION_SETTINGS = {
    "send_whatsapp_replies" => true,
    "create_alerts" => true,
    "send_urgent_emails" => true
  }.freeze

  has_many :users, dependent: :destroy
  has_many :properties, dependent: :destroy
  has_many :guests, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :billing_events, dependent: :nullify

  validates :name, presence: true
  validates :slug, uniqueness: true, allow_blank: true
  validates :ai_response_style, inclusion: { in: AI_RESPONSE_STYLES }
  validates :ai_default_channel, inclusion: { in: AI_CHANNELS }
  validates :ai_preferred_language, inclusion: { in: AI_LANGUAGES }

  before_validation :assign_slug, on: :create
  before_validation :normalize_ai_configuration

  def active_subscription
    subscriptions.order(created_at: :desc).first
  end

  def property_limit
    active_subscription&.property_limit || Subscription::PLAN_LIMITS.fetch("starter")
  end

  def can_add_property?
    property_limit.nil? || properties.count < property_limit
  end

  def ai_escalates?(alert_type)
    ai_escalation_rules.fetch(alert_type.to_s, true)
  end

  def ai_automation_enabled?(setting)
    ai_automation_settings.fetch(setting.to_s, true)
  end

  private

  def normalize_ai_configuration
    self.ai_escalation_rules = DEFAULT_ESCALATION_RULES.merge((ai_escalation_rules || {}).deep_stringify_keys)
    self.ai_automation_settings = DEFAULT_AUTOMATION_SETTINGS.merge((ai_automation_settings || {}).deep_stringify_keys)
    self.ai_preferred_language = "es" unless AI_LANGUAGES.include?(ai_preferred_language.to_s)
    self.languages_supported = "Español, Inglés"
  end

  def assign_slug
    return if slug.present?

    base = name.to_s.parameterize.presence || "ayla-manager"
    candidate = base
    counter = 2

    while self.class.exists?(slug: candidate)
      candidate = "#{base}-#{counter}"
      counter += 1
    end

    self.slug = candidate
  end
end
