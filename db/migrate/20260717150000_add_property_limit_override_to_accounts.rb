class AddPropertyLimitOverrideToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :property_limit_override, :integer
    add_check_constraint :accounts,
      "property_limit_override IS NULL OR property_limit_override >= 0",
      name: "accounts_property_limit_override_non_negative"
  end
end
