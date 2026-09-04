class KnowledgeBlock < ApplicationRecord
  YOUTUBE_HOSTS = %w[youtube.com www.youtube.com m.youtube.com youtu.be].freeze
  CATEGORIES = %w[
    check_in
    checkout
    wifi
    appliances
    house_rules
    amenities
    building_access
    transportation
    emergencies
    custom_notes
  ].freeze
  STATUSES = %w[active inactive draft].freeze

  belongs_to :property

  validates :title, :content, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validate :youtube_url_is_safe

  scope :active, -> { where(status: "active") }

  private

  def youtube_url_is_safe
    return if youtube_url.blank?

    uri = URI.parse(youtube_url)
    valid = uri.is_a?(URI::HTTPS) &&
      uri.userinfo.nil? &&
      uri.port == 443 &&
      YOUTUBE_HOSTS.include?(uri.host.to_s.downcase)
    errors.add(:youtube_url, "debe ser un link HTTPS de YouTube válido") unless valid
  rescue URI::InvalidURIError
    errors.add(:youtube_url, "debe ser un link HTTPS de YouTube válido")
  end
end
