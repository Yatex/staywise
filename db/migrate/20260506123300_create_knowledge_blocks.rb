class CreateKnowledgeBlocks < ActiveRecord::Migration[7.1]
  def change
    create_table :knowledge_blocks do |t|
      t.references :property, null: false, foreign_key: true
      t.string :title, null: false
      t.string :category, null: false
      t.text :content, null: false
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :knowledge_blocks, [:property_id, :category]
    add_index :knowledge_blocks, [:property_id, :status]
  end
end
