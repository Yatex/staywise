class CreateBillingEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :billing_events do |t|
      t.references :account, null: true, foreign_key: true
      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}

      t.timestamps
    end

    add_index :billing_events, :stripe_event_id, unique: true
    add_index :billing_events, :event_type
  end
end
