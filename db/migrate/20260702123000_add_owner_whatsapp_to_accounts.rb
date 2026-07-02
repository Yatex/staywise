class AddOwnerWhatsappToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :owner_whatsapp_number, :string
    add_column :accounts, :owner_whatsapp_escalations_enabled, :boolean, default: false, null: false
    add_index :accounts, :owner_whatsapp_number
  end
end
