class AddConversationTranslationPreferences < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :preferred_conversation_language, :string, null: false, default: "es"
    add_column :co_hosts, :preferred_conversation_language, :string, null: false, default: "es"
    add_column :messages, :detected_language, :string

    create_table :message_translations do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.string :target_language, null: false
      t.text :translated_body
      t.string :source_language
      t.string :provider
      t.string :model
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.timestamps
    end

    add_index :message_translations, [:message_id, :target_language], unique: true
    add_check_constraint :message_translations,
      "status IN ('pending', 'processing', 'completed', 'failed')",
      name: "message_translations_status_check"
  end
end
