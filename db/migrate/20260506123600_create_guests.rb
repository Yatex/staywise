class CreateGuests < ActiveRecord::Migration[7.1]
  def change
    create_table :guests do |t|
      t.references :account, null: false, foreign_key: true
      t.references :property, null: true, foreign_key: true
      t.string :name
      t.string :phone_number, null: false
      t.string :language
      t.string :reservation_reference
      t.date :check_in_date
      t.date :checkout_date

      t.timestamps
    end

    add_index :guests, [:account_id, :phone_number], unique: true
  end
end
