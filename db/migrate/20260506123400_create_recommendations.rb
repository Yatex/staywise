class CreateRecommendations < ActiveRecord::Migration[7.1]
  def change
    create_table :recommendations do |t|
      t.references :property, null: false, foreign_key: true
      t.string :name, null: false
      t.string :category, null: false
      t.text :description
      t.string :address
      t.string :google_maps_url
      t.string :website_url
      t.string :phone_number
      t.text :owner_note
      t.string :distance_or_walking_time

      t.timestamps
    end

    add_index :recommendations, [:property_id, :category]
  end
end
