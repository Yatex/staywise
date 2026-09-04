class RemoveLegacyCopilotClarifyingQuestion < ActiveRecord::Migration[7.1]
  def change
    remove_column :copilot_runs, :clarifying_question, :text
  end
end
