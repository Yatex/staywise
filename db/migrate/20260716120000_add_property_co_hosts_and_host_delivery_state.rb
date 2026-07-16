class AddPropertyCoHostsAndHostDeliveryState < ActiveRecord::Migration[7.1]
  ACTIVE_SESSION_STATES = %w[menu viewing_item awaiting_reply_text awaiting_send_confirmation awaiting_learning_confirmation].freeze

  def change
    create_table :co_hosts do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :whatsapp_number, null: false
      t.timestamps
    end
    add_index :co_hosts, :whatsapp_number, unique: true

    add_reference :properties, :co_host, foreign_key: true

    add_reference :owner_whatsapp_sessions, :co_host, foreign_key: true
    add_column :owner_whatsapp_sessions, :participant_phone, :string
    add_column :owner_whatsapp_sessions, :actor_role, :string, default: "owner", null: false
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE owner_whatsapp_sessions AS sessions
          SET participant_phone = COALESCE(accounts.owner_whatsapp_number, 'account:' || sessions.account_id::text)
          FROM accounts
          WHERE accounts.id = sessions.account_id
        SQL
      end
    end
    change_column_null :owner_whatsapp_sessions, :participant_phone, false
    reversible do |direction|
      direction.up do
        remove_index :owner_whatsapp_sessions, name: "index_one_active_owner_whatsapp_session_per_account"
        add_index :owner_whatsapp_sessions, [:account_id, :participant_phone], unique: true,
          where: "state IN (#{ACTIVE_SESSION_STATES.map { |state| connection.quote(state) }.join(', ')})",
          name: "index_one_active_host_session_per_participant"
      end
      direction.down do
        remove_index :owner_whatsapp_sessions, name: "index_one_active_host_session_per_participant"
        add_index :owner_whatsapp_sessions, :account_id, unique: true,
          where: "state IN (#{ACTIVE_SESSION_STATES.map { |state| connection.quote(state) }.join(', ')})",
          name: "index_one_active_owner_whatsapp_session_per_account"
      end
    end
    add_check_constraint :owner_whatsapp_sessions, "actor_role IN ('owner', 'co_host')", name: "owner_sessions_actor_role_check"

    add_delivery_columns(:guest_requests)
    add_delivery_columns(:alerts)
  end

  private

  def add_delivery_columns(table)
    add_column table, :response_delivery_state, :string, default: "pending", null: false
    add_column table, :claimed_response_body, :text
    add_column table, :final_response_body, :text
    add_column table, :resolved_by_actor_type, :string
    add_column table, :resolved_by_actor_id, :bigint
    add_column table, :resolved_by_role, :string
    add_column table, :source_owner_message_sid, :string
    add_index table, :response_delivery_state
    add_index table, :source_owner_message_sid, unique: true, where: "source_owner_message_sid IS NOT NULL",
      name: "index_#{table}_on_source_owner_message_sid_unique"
    add_check_constraint table,
      "response_delivery_state IN ('pending', 'sending', 'responded', 'failed')",
      name: "#{table}_response_delivery_state_check"
  end
end
