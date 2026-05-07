class CreateFaqs < ActiveRecord::Migration[7.1]
  def change
    create_table :faqs do |t|
      t.references :property, null: false, foreign_key: true
      t.string :question, null: false
      t.text :answer, null: false
      t.string :category
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :faqs, [:property_id, :active]
  end
end
