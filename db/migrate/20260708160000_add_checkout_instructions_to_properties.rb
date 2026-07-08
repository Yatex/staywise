class AddCheckoutInstructionsToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :checkout_instructions, :text
  end
end
