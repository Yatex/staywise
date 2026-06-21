class AddYoutubeUrlToKnowledgeBlocks < ActiveRecord::Migration[7.1]
  def change
    add_column :knowledge_blocks, :youtube_url, :string
  end
end
