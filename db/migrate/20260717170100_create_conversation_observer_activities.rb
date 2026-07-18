class CreateConversationObserverActivities < ActiveRecord::Migration[7.1]
  def change
    create_table :conversation_observer_activities do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.string :observer_type, null: false
      t.bigint :observer_id, null: false
      t.datetime :last_activity_at, null: false
      t.datetime :observer_notified_at
      t.datetime :observer_seen_at
      t.integer :unread_activity_count, null: false, default: 0
      t.string :latest_message_direction, null: false
      t.text :last_notification_error
      t.timestamps
    end

    add_index :conversation_observer_activities,
      [:observer_type, :observer_id, :conversation_id],
      unique: true,
      name: "index_observer_activities_unique_recipient_conversation"
    add_index :conversation_observer_activities,
      [:observer_type, :observer_id, :observer_seen_at, :last_activity_at],
      name: "index_observer_activities_pending_by_recipient"
    add_check_constraint :conversation_observer_activities,
      "unread_activity_count >= 0",
      name: "observer_activities_unread_non_negative"
  end
end
