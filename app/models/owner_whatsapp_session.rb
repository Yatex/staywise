class OwnerWhatsappSession < ApplicationRecord
  STATES = %w[queued awaiting_ack awaiting_answer on_hold menu awaiting_owner_reply viewing_item awaiting_reply_text awaiting_send_confirmation awaiting_learning_confirmation resolved failed].freeze
  ACTIVE_STATES = %w[menu viewing_item awaiting_reply_text awaiting_send_confirmation awaiting_learning_confirmation].freeze

  belongs_to :account
  belongs_to :alert, optional: true
  belongs_to :co_host, optional: true

  validates :state, inclusion: { in: STATES }
  validates :actor_role, inclusion: { in: %w[owner co_host] }
  validates :participant_phone, presence: true
  before_validation :set_participant_identity

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :pending, -> { where(state: %w[queued on_hold]) }
  scope :unresolved, -> { where.not(state: %w[resolved failed]) }

  def active?
    state.in?(ACTIVE_STATES)
  end

  def active_item
    return if active_item_type.blank? || active_item_id.blank?

    active_item_type.constantize.find_by(id: active_item_id)
  end

  def draft_for_active_item?
    draft_reply_body.present? && draft_item_type == active_item_type && draft_item_id == active_item_id
  end

  def append_event!(type, payload = {})
    events = Array(metadata["events"])
    update!(
      metadata: metadata.merge(
        "events" => events.last(49) + [
          payload.compact.merge(
            "type" => type,
            "at" => Time.current.iso8601
          )
        ]
      )
    )
  end

  private

  def set_participant_identity
    self.actor_role = co_host_id.present? ? "co_host" : "owner"
    self.participant_phone ||= co_host&.whatsapp_number || account&.owner_whatsapp_number || "account:#{account_id}"
  end
end
