class AddReviewMetadataToFaqs < ActiveRecord::Migration[7.1]
  def change
    add_column :faqs, :status, :string, null: false, default: "approved"
    add_column :faqs, :source_type, :string, null: false, default: "manual"
    add_reference :faqs, :source_alert, foreign_key: { to_table: :alerts }
    add_reference :faqs, :source_message, foreign_key: { to_table: :messages }
    add_column :faqs, :metadata, :jsonb, null: false, default: {}

    add_index :faqs, [:property_id, :status]
    add_index :faqs, [:property_id, :source_type]
  end
end
