class AddTraceLinksToAlerts < ActiveRecord::Migration[7.1]
  def change
    add_reference :alerts, :original_message, foreign_key: { to_table: :messages }
    add_reference :alerts, :ai_decision_log, foreign_key: true
    add_column :alerts, :metadata, :jsonb, null: false, default: {}
  end
end
