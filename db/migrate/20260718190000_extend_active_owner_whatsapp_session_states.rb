class ExtendActiveOwnerWhatsappSessionStates < ActiveRecord::Migration[7.1]
  ACTIVE_STATES = %w[
    menu viewing_item awaiting_reply_text awaiting_send_confirmation
    sending_guest_message awaiting_learning_confirmation loading_next_case
  ].freeze

  def up
    execute <<~SQL.squish
      UPDATE owner_whatsapp_sessions
      SET state = 'resolved',
          resolved_at = COALESCE(resolved_at, CURRENT_TIMESTAMP),
          active_category = NULL,
          active_item_type = NULL,
          active_item_id = NULL,
          draft_reply_body = NULL,
          draft_item_type = NULL,
          draft_item_id = NULL
      WHERE state IN ('awaiting_ack', 'awaiting_answer', 'awaiting_owner_reply')
    SQL

    remove_index :owner_whatsapp_sessions, name: "index_one_active_host_session_per_participant"
    add_index :owner_whatsapp_sessions, %i[account_id participant_phone],
      unique: true,
      name: "index_one_active_host_session_per_participant",
      where: "state IN (#{ACTIVE_STATES.map { |state| connection.quote(state) }.join(', ')})"
  end

  def down
    remove_index :owner_whatsapp_sessions, name: "index_one_active_host_session_per_participant"
    add_index :owner_whatsapp_sessions, %i[account_id participant_phone],
      unique: true,
      name: "index_one_active_host_session_per_participant",
      where: "state IN ('menu', 'viewing_item', 'awaiting_reply_text', 'awaiting_send_confirmation', 'awaiting_learning_confirmation')"
  end
end
