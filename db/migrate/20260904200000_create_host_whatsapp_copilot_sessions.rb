class CreateHostWhatsappCopilotSessions < ActiveRecord::Migration[7.1]
  def change
    add_index :accounts, :owner_whatsapp_number,
      unique: true,
      where: "owner_whatsapp_number IS NOT NULL",
      name: "index_accounts_on_unique_owner_whatsapp_number"

    create_table :host_whatsapp_copilot_sessions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :co_host, null: true, foreign_key: true
      t.references :selected_property, null: true, foreign_key: { to_table: :properties }
      t.references :copilot_thread, null: true, foreign_key: true
      t.string :participant_phone, null: false
      t.string :actor_role, null: false
      t.string :state, null: false, default: "awaiting_property"
      t.datetime :last_activity_at, null: false
      t.string :last_inbound_message_sid
      t.jsonb :delivery_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :host_whatsapp_copilot_sessions, :participant_phone, unique: true, name: "index_host_copilot_sessions_on_phone"
    add_index :host_whatsapp_copilot_sessions, :last_activity_at
    add_check_constraint :host_whatsapp_copilot_sessions,
      "state IN ('awaiting_property', 'awaiting_guest_message', 'active_thread')",
      name: "host_copilot_sessions_state_check"
    add_check_constraint :host_whatsapp_copilot_sessions,
      "actor_role IN ('owner', 'co_host')",
      name: "host_copilot_sessions_actor_role_check"

    add_column :copilot_threads, :source, :string, null: false, default: "web"
    add_column :copilot_runs, :source, :string, null: false, default: "web"
    add_column :copilot_runs, :channel_metadata, :jsonb, null: false, default: {}
    add_check_constraint :copilot_threads, "source IN ('web', 'whatsapp')", name: "copilot_threads_source_check"
    add_check_constraint :copilot_runs, "source IN ('web', 'whatsapp')", name: "copilot_runs_source_check"
  end
end
