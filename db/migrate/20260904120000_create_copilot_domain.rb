class CreateCopilotDomain < ActiveRecord::Migration[7.1]
  def change
    create_table :copilot_threads do |t|
      t.references :account, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "active"
      t.string :title
      t.datetime :last_message_at
      t.timestamps
    end

    add_index :copilot_threads, [:account_id, :user_id, :last_message_at], name: "index_copilot_threads_for_user"
    add_check_constraint :copilot_threads, "status IN ('active', 'archived')", name: "copilot_threads_status_check"

    create_table :copilot_messages do |t|
      t.references :copilot_thread, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false
      t.text :host_context
      t.jsonb :structured_content, null: false, default: {}
      t.timestamps
    end

    add_index :copilot_messages, [:copilot_thread_id, :created_at]
    add_check_constraint :copilot_messages, "role IN ('host', 'assistant')", name: "copilot_messages_role_check"

    create_table :copilot_runs do |t|
      t.references :copilot_thread, null: false, foreign_key: true
      t.references :copilot_message, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :property, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :detected_language
      t.text :guest_question_es
      t.text :answer_summary_es
      t.text :guest_reply
      t.integer :confidence
      t.boolean :missing_information, null: false, default: false
      t.text :clarifying_question
      t.jsonb :evidence_refs, null: false, default: []
      t.jsonb :tool_calls, null: false, default: []
      t.string :error_type
      t.text :error_message
      t.string :correlation_id
      t.integer :latency_ms
      t.timestamps
    end

    add_index :copilot_runs, [:copilot_thread_id, :created_at]
    add_index :copilot_runs, :correlation_id
    add_check_constraint :copilot_runs, "status IN ('pending', 'completed', 'failed')", name: "copilot_runs_status_check"
    add_check_constraint :copilot_runs, "confidence IS NULL OR (confidence >= 0 AND confidence <= 100)", name: "copilot_runs_confidence_check"
  end
end
