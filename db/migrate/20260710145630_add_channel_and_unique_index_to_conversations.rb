class AddChannelAndUniqueIndexToConversations < ActiveRecord::Migration[7.1]
  INDEX_NAME = "index_conversations_on_guest_id_and_channel_unique".freeze

  disable_ddl_transaction!

  def up
    add_column :conversations, :channel, :string, default: "whatsapp" unless column_exists?(:conversations, :channel)
    change_column_null :conversations, :channel, false, "whatsapp"
    execute("UPDATE conversations SET channel = 'whatsapp' WHERE channel IS NULL OR channel = ''")

    if duplicate_groups_exist?
      say "Skipped #{INDEX_NAME}: duplicate guest/channel conversations exist. Run bin/rails conversations:deduplicate, then bin/rails conversations:add_unique_index.", true
      return
    end

    add_index :conversations, [:guest_id, :channel], unique: true, name: INDEX_NAME, algorithm: :concurrently unless index_exists?(:conversations, [:guest_id, :channel], name: INDEX_NAME)
  end

  def down
    remove_index :conversations, name: INDEX_NAME if index_exists?(:conversations, [:guest_id, :channel], name: INDEX_NAME)
    remove_column :conversations, :channel if column_exists?(:conversations, :channel)
  end

  private

  def duplicate_groups_exist?
    select_value(<<~SQL).to_i.positive?
      SELECT COUNT(*)
      FROM (
        SELECT guest_id, COALESCE(NULLIF(channel, ''), 'whatsapp') AS normalized_channel
        FROM conversations
        GROUP BY guest_id, COALESCE(NULLIF(channel, ''), 'whatsapp')
        HAVING COUNT(*) > 1
      ) duplicate_groups
    SQL
  end
end
