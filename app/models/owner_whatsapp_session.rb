class OwnerWhatsappSession < ApplicationRecord
  STATES = %w[queued awaiting_ack awaiting_answer on_hold menu awaiting_owner_reply awaiting_learning_confirmation resolved failed].freeze
  ACTIVE_STATES = %w[menu awaiting_owner_reply awaiting_learning_confirmation].freeze

  belongs_to :account
  belongs_to :alert, optional: true

  validates :state, inclusion: { in: STATES }

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
end
