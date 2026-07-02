class CreateOwnerWhatsappSessions < ActiveRecord::Migration[7.1]
  def change
    create_table :owner_whatsapp_sessions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :alert, null: false, foreign_key: true, index: { unique: true }
      t.string :state, default: "queued", null: false
      t.datetime :last_prompted_at
      t.datetime :last_owner_message_at
      t.datetime :resolved_at
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :owner_whatsapp_sessions, [:account_id, :state]
  end
end
