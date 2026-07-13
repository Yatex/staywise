class AddDraftReplyToOwnerWhatsappSessions < ActiveRecord::Migration[7.1]
  ACTIVE_STATES = %w[menu viewing_item awaiting_reply_text awaiting_send_confirmation awaiting_learning_confirmation].freeze

  def change
    add_column :owner_whatsapp_sessions, :draft_reply_body, :text
    add_column :owner_whatsapp_sessions, :draft_item_type, :string
    add_column :owner_whatsapp_sessions, :draft_item_id, :bigint

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE owner_whatsapp_sessions
          SET state = 'viewing_item'
          WHERE state = 'awaiting_owner_reply'
        SQL
      end
    end

    remove_index :owner_whatsapp_sessions, name: "index_one_active_owner_whatsapp_session_per_account"
    add_index :owner_whatsapp_sessions, :account_id,
      unique: true,
      where: "state IN (#{ACTIVE_STATES.map { |state| connection.quote(state) }.join(', ')})",
      name: "index_one_active_owner_whatsapp_session_per_account"
  end
end
