class CreatePropertySensitiveData < ActiveRecord::Migration[7.1]
  def change
    create_table :property_sensitive_data do |t|
      t.references :property, null: false, foreign_key: true
      t.string :kind, null: false
      t.text :encrypted_value, null: false
      t.boolean :active, null: false, default: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :source_alert, foreign_key: { to_table: :alerts }
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :property_sensitive_data, [:property_id, :kind, :active], name: "index_property_sensitive_data_on_property_kind_active"
  end
end
