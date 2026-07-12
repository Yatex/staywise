class ReworkOwnerWhatsappSessionsForQueue < ActiveRecord::Migration[7.1]
  def change
    change_column_null :owner_whatsapp_sessions, :alert_id, true
    add_column :owner_whatsapp_sessions, :active_category, :string
    add_column :owner_whatsapp_sessions, :active_item_type, :string
    add_column :owner_whatsapp_sessions, :active_item_id, :bigint
    add_column :owner_whatsapp_sessions, :started_at, :datetime
    add_column :owner_whatsapp_sessions, :expires_at, :datetime
    add_column :owner_whatsapp_sessions, :processed_message_sids, :jsonb, default: [], null: false

    add_index :owner_whatsapp_sessions, [:active_item_type, :active_item_id], name: "index_owner_sessions_on_active_item"
    add_index :owner_whatsapp_sessions, :account_id,
      unique: true,
      where: "state IN ('menu', 'awaiting_owner_reply', 'awaiting_learning_confirmation')",
      name: "index_one_active_owner_whatsapp_session_per_account"
  end
end
