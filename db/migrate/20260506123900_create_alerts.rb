class CreateAlerts < ActiveRecord::Migration[7.1]
  def change
    create_table :alerts do |t|
      t.references :property, null: false, foreign_key: true
      t.references :guest, null: true, foreign_key: true
      t.references :conversation, null: true, foreign_key: true
      t.string :alert_type, null: false
      t.string :title, null: false
      t.text :description
      t.string :status, null: false, default: "open"
      t.string :priority, null: false, default: "medium"
      t.text :ai_suggested_action
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :alerts, [:property_id, :status]
    add_index :alerts, [:alert_type, :priority]
  end
end
