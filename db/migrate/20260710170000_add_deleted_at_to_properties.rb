class AddDeletedAtToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :deleted_at, :datetime
    add_index :properties, :deleted_at
  end
end
