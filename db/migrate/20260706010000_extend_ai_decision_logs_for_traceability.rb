class ExtendAIDecisionLogsForTraceability < ActiveRecord::Migration[7.1]
  def change
    add_reference :ai_decision_logs, :original_message, foreign_key: { to_table: :messages }
    add_column :ai_decision_logs, :ai_request_payload, :jsonb, default: {}, null: false
    add_column :ai_decision_logs, :ai_response_payload, :jsonb, default: {}, null: false
    add_column :ai_decision_logs, :tool_calls, :jsonb, default: [], null: false
    add_column :ai_decision_logs, :validation_results, :jsonb, default: {}, null: false
    add_column :ai_decision_logs, :fallback_reason, :string
    add_column :ai_decision_logs, :final_outcome, :string
    add_column :ai_decision_logs, :provider_delivery_status, :string

    add_index :ai_decision_logs, [:final_outcome, :created_at]
    add_index :ai_decision_logs, [:fallback_reason, :created_at]
    add_index :ai_decision_logs, [:provider_delivery_status, :created_at]
  end
end
