class AddAnswerConfidenceAndPropertyContact < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :ai_answer_confidence_threshold, :integer, default: 90, null: false
    add_column :properties, :owner_contact_phone, :string
  end
end
