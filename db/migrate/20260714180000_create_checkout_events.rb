class CreateCheckoutEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :checkout_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.references :guest, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true, index: false
      t.references :source_message, null: false, foreign_key: { to_table: :messages }, index: false
      t.string :provider_message_sid
      t.string :reservation_key, null: false
      t.text :guest_message_body, null: false
      t.datetime :checked_out_at, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :owner_seen_at

      t.timestamps
    end

    add_index :checkout_events, [:account_id, :reservation_key], unique: true
    add_index :checkout_events, :source_message_id, unique: true
    add_index :checkout_events, :provider_message_sid, unique: true, where: "provider_message_sid IS NOT NULL"
    add_index :checkout_events, [:account_id, :status, :created_at]
  end
end
