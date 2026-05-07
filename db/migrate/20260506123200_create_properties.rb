class CreateProperties < ActiveRecord::Migration[7.1]
  def change
    create_table :properties do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :address
      t.string :internal_nickname
      t.string :check_in_time
      t.string :checkout_time
      t.string :wifi_name
      t.string :wifi_password
      t.text :house_rules
      t.text :access_instructions
      t.text :parking_instructions
      t.text :emergency_information
      t.text :owner_contact_instructions
      t.text :ai_general_notes
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :properties, [:account_id, :name]
  end
end
