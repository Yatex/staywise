class CreateAIDecisionLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_decision_logs do |t|
      t.references :account, foreign_key: true
      t.references :property, foreign_key: true
      t.references :guest, foreign_key: true
      t.references :conversation, foreign_key: true
      t.references :message, foreign_key: true
      t.string :route, null: false
      t.string :decision
      t.string :language
      t.string :validator_result
      t.text :rejection_reason
      t.boolean :escalation_required, default: false, null: false
      t.boolean :replied_candidate, default: false, null: false
      t.integer :latency_ms
      t.string :model
      t.jsonb :detected_intents, default: [], null: false
      t.jsonb :evidence_ids, default: [], null: false
      t.jsonb :missing_information, default: [], null: false
      t.jsonb :safety_flags, default: [], null: false
      t.jsonb :payload, default: {}, null: false

      t.timestamps
    end

    add_index :ai_decision_logs, [:property_id, :created_at]
    add_index :ai_decision_logs, [:route, :created_at]
    add_index :ai_decision_logs, [:validator_result, :created_at]
  end
end
