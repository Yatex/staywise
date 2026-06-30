class CreateOperationalErrors < ActiveRecord::Migration[7.1]
  def change
    create_table :operational_errors do |t|
      t.references :account, foreign_key: true
      t.references :property, foreign_key: true
      t.string :source, null: false
      t.string :severity, null: false, default: "error"
      t.string :error_class
      t.text :message, null: false
      t.jsonb :context, null: false, default: {}
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :operational_errors, [:source, :created_at]
    add_index :operational_errors, [:severity, :created_at]
    add_index :operational_errors, :resolved_at
  end
end
