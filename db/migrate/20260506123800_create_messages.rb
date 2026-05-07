class CreateMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :sender, null: false
      t.text :body, null: false
      t.string :channel, null: false, default: "whatsapp"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :messages, [:conversation_id, :created_at]
    add_index :messages, :sender
  end
end
