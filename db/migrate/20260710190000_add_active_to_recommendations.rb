class AddActiveToRecommendations < ActiveRecord::Migration[7.1]
  def change
    add_column :recommendations, :active, :boolean, null: false, default: true
    add_index :recommendations, [:property_id, :active, :category]
  end
end
