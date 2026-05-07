class AddTagsAndAIConfiguration < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :tags, :string, array: true, null: false, default: []
    add_column :properties, :ai_enabled, :boolean, null: false, default: true

    add_column :accounts, :ai_active, :boolean, null: false, default: true
    add_column :accounts, :ai_goal, :text
    add_column :accounts, :ai_response_style, :string, null: false, default: "concise"
    add_column :accounts, :ai_preferred_language, :string, null: false, default: "auto"
    add_column :accounts, :ai_default_channel, :string, null: false, default: "whatsapp"
    add_column :accounts, :ai_escalation_rules, :jsonb, null: false, default: {}
    add_column :accounts, :ai_automation_settings, :jsonb, null: false, default: {}

    add_index :properties, :tags, using: :gin
  end
end
