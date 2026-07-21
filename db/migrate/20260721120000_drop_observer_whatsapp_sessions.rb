class DropObserverWhatsappSessions < ActiveRecord::Migration[7.1]
  def change
    drop_table :observer_whatsapp_sessions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :co_host, foreign_key: true
      t.references :current_activity, foreign_key: { to_table: :conversation_observer_activities }
      t.string :participant_phone, null: false
      t.string :actor_role, null: false
      t.string :state, null: false, default: "active"
      t.datetime :started_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_prompted_at
      t.datetime :resolved_at
      t.jsonb :processed_message_sids, null: false, default: []
      t.timestamps

      t.index [:account_id, :participant_phone], unique: true, where: "state = 'active'",
        name: "index_one_active_observer_session_per_participant"
    end
  end
end
