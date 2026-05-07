class CreateConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :conversations do |t|
      t.references :guest, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.string :status, null: false, default: "active"
      t.datetime :last_message_at
      t.boolean :ai_enabled, null: false, default: true

      t.timestamps
    end

    add_index :conversations, [:property_id, :status]
    add_index :conversations, :last_message_at
  end
end
