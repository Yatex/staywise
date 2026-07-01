class AddPublicTokenToProperties < ActiveRecord::Migration[7.1]
  class PropertyRecord < ActiveRecord::Base
    self.table_name = "properties"
  end

  def up
    add_column :properties, :public_token, :string

    PropertyRecord.reset_column_information
    PropertyRecord.find_each do |property|
      property.update_columns(public_token: unique_public_token)
    end

    change_column_null :properties, :public_token, false
    add_index :properties, :public_token, unique: true
  end

  def down
    remove_index :properties, :public_token
    remove_column :properties, :public_token
  end

  private

  def unique_public_token
    loop do
      token = SecureRandom.base58(24)
      break token unless PropertyRecord.exists?(public_token: token)
    end
  end
end
