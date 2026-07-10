class CreateGuestRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :guest_requests do |t|
      t.references :account, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :guest, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true
      t.references :ai_decision_log, foreign_key: true
      t.string :guest_phone, null: false
      t.string :property_name, null: false
      t.string :property_address
      t.string :category, null: false
      t.string :title, null: false
      t.text :description, null: false
      t.text :ai_summary
      t.string :status, null: false, default: "pending"
      t.string :priority, null: false, default: "normal"
      t.string :source_channel, null: false, default: "whatsapp"
      t.jsonb :metadata, null: false, default: {}
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :guest_requests, [:account_id, :status]
    add_index :guest_requests, [:property_id, :status]
    add_index :guest_requests, [:conversation_id, :created_at]
    add_index :guest_requests, [:category, :created_at]
  end
end
