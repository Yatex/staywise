class CreateOwnerReplyDrafts < ActiveRecord::Migration[7.1]
  def change
    create_table :owner_reply_drafts do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.references :co_host, foreign_key: true
      t.text :original_body, null: false
      t.text :translated_body
      t.text :sent_body
      t.string :source_language
      t.string :target_language
      t.string :translation_provider
      t.string :translation_model
      t.string :translation_status, null: false, default: "not_requested"
      t.string :confirmed_by
      t.datetime :confirmed_at
      t.text :error_message
      t.timestamps
    end
  end
end
