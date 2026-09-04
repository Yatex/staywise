class SplitCopilotClarifyingQuestion < ActiveRecord::Migration[7.1]
  def change
    add_column :copilot_runs, :clarifying_question_es, :text
    add_column :copilot_runs, :clarifying_question_guest, :text
  end
end
