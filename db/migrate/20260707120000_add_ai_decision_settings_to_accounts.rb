class AddAIDecisionSettingsToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :ai_high_score_threshold, :integer, default: 75, null: false
    add_column :accounts, :ai_medium_score_threshold, :integer, default: 40, null: false
    add_column :accounts, :ai_safety_score_threshold, :integer, default: 75, null: false
    add_column :accounts, :ai_max_clarification_attempts, :integer, default: 2, null: false
  end
end
