class Account < ApplicationRecord
  AI_RESPONSE_STYLES = %w[concise warm detailed].freeze
  AI_CHANNELS = %w[whatsapp].freeze
  AI_LANGUAGES = %w[en es].freeze
  DEFAULT_AI_DECISION_SETTINGS = {
    answer_confidence_threshold: 90,
    high_score_threshold: 75,
    medium_score_threshold: 40,
    safety_score_threshold: 75,
    max_clarification_attempts: 2
  }.freeze
  DEFAULT_ESCALATION_RULES = {
    "late_checkout_request" => true,
    "missing_item" => true,
    "maintenance_issue" => true,
    "emergency" => true,
    "complaint" => true,
    "owner_approval_required" => true,
    "missing_sensitive_information" => true,
    "unknown_question" => true
  }.freeze
  DEFAULT_AUTOMATION_SETTINGS = {
    "send_whatsapp_replies" => true,
    "create_alerts" => true,
    "send_urgent_emails" => true,
    "send_owner_whatsapp_escalations" => true
  }.freeze

  has_many :users, dependent: :destroy
  has_many :properties, dependent: :destroy
  has_many :guests, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :billing_events, dependent: :nullify
  has_many :operational_errors, dependent: :nullify
  has_many :owner_whatsapp_sessions, dependent: :destroy
  has_many :owner_tasks, dependent: :destroy
  has_many :guest_requests, -> { requests }, class_name: "OwnerTask"

  validates :name, presence: true
  validates :slug, uniqueness: true, allow_blank: true
  validates :ai_response_style, inclusion: { in: AI_RESPONSE_STYLES }
  validates :ai_default_channel, inclusion: { in: AI_CHANNELS }
  validates :ai_preferred_language, inclusion: { in: AI_LANGUAGES }
  validates :ai_answer_confidence_threshold, :ai_high_score_threshold, :ai_medium_score_threshold, :ai_safety_score_threshold,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :ai_max_clarification_attempts,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 10 }
  validate :ai_decision_threshold_order

  before_validation :assign_slug, on: :create
  before_validation :normalize_ai_configuration
  before_validation :normalize_owner_whatsapp_number

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

  def ai_decision_settings
    {
      high_score_threshold: ai_high_score_threshold || DEFAULT_AI_DECISION_SETTINGS.fetch(:high_score_threshold),
      answer_confidence_threshold: ai_answer_confidence_threshold || DEFAULT_AI_DECISION_SETTINGS.fetch(:answer_confidence_threshold),
      medium_score_threshold: ai_medium_score_threshold || DEFAULT_AI_DECISION_SETTINGS.fetch(:medium_score_threshold),
      safety_score_threshold: ai_safety_score_threshold || DEFAULT_AI_DECISION_SETTINGS.fetch(:safety_score_threshold),
      max_clarification_attempts: ai_max_clarification_attempts || DEFAULT_AI_DECISION_SETTINGS.fetch(:max_clarification_attempts)
    }
  end

  def owner_whatsapp_configured?
    owner_whatsapp_escalations_enabled? && owner_whatsapp_number.present?
  end

  private

  def normalize_ai_configuration
    self.ai_escalation_rules = DEFAULT_ESCALATION_RULES.merge((ai_escalation_rules || {}).deep_stringify_keys)
    self.ai_automation_settings = DEFAULT_AUTOMATION_SETTINGS.merge((ai_automation_settings || {}).deep_stringify_keys)
    self.ai_preferred_language = "es" unless AI_LANGUAGES.include?(ai_preferred_language.to_s)
    self.languages_supported = "Español, Inglés"
    self.ai_high_score_threshold ||= DEFAULT_AI_DECISION_SETTINGS.fetch(:high_score_threshold)
    self.ai_answer_confidence_threshold ||= DEFAULT_AI_DECISION_SETTINGS.fetch(:answer_confidence_threshold)
    self.ai_medium_score_threshold ||= DEFAULT_AI_DECISION_SETTINGS.fetch(:medium_score_threshold)
    self.ai_safety_score_threshold ||= DEFAULT_AI_DECISION_SETTINGS.fetch(:safety_score_threshold)
    self.ai_max_clarification_attempts ||= DEFAULT_AI_DECISION_SETTINGS.fetch(:max_clarification_attempts)
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

  def normalize_owner_whatsapp_number
    self.owner_whatsapp_number = owner_whatsapp_number.to_s.gsub(/\Awhatsapp:/, "").strip.presence
  end

  def ai_decision_threshold_order
    return if ai_high_score_threshold.blank? || ai_medium_score_threshold.blank?
    return if ai_high_score_threshold >= ai_medium_score_threshold

    errors.add(:ai_high_score_threshold, "debe ser mayor o igual al threshold medio")
  end
end
