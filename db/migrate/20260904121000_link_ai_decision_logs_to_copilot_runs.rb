class LinkAIDecisionLogsToCopilotRuns < ActiveRecord::Migration[7.1]
  def change
    add_reference :ai_decision_logs, :copilot_run, foreign_key: true
  end
end
