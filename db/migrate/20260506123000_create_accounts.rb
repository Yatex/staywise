class CreateAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :slug
      t.text :default_ai_instructions
      t.string :ai_tone, null: false, default: "friendly"
      t.string :languages_supported
      t.text :unsure_behavior
      t.string :late_checkout_policy, null: false, default: "always_escalate"
      t.text :emergency_contact_behavior
      t.boolean :whatsapp_enabled, null: false, default: false
      t.boolean :email_alerts_enabled, null: false, default: true

      t.timestamps
    end

    add_index :accounts, :slug, unique: true
  end
end
