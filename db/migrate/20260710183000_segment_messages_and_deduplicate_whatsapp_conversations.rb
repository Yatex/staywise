class SegmentMessagesAndDeduplicateWhatsappConversations < ActiveRecord::Migration[7.1]
  CONVERSATION_THREAD_INDEX = "index_conversations_on_channel_and_channel_participant".freeze
  MESSAGE_ACCOUNT_INDEX = "index_messages_on_account_id_conversation_id_created_at".freeze

  disable_ddl_transaction!

  def up
    add_reference :messages, :account, foreign_key: true, index: true unless column_exists?(:messages, :account_id)
    add_reference :messages, :property, foreign_key: true, index: true unless column_exists?(:messages, :property_id)
    add_column :conversations, :channel_participant, :string unless column_exists?(:conversations, :channel_participant)

    backfill_message_tenant_columns
    backfill_conversation_participants
    deduplicate_conversations

    change_column_null :conversations, :channel_participant, false
    add_index :conversations, [:channel, :channel_participant], unique: true, name: CONVERSATION_THREAD_INDEX, algorithm: :concurrently unless index_exists?(:conversations, [:channel, :channel_participant], name: CONVERSATION_THREAD_INDEX)
    add_index :messages, [:account_id, :conversation_id, :created_at], name: MESSAGE_ACCOUNT_INDEX, algorithm: :concurrently unless index_exists?(:messages, [:account_id, :conversation_id, :created_at], name: MESSAGE_ACCOUNT_INDEX)
  end

  def down
    remove_index :messages, name: MESSAGE_ACCOUNT_INDEX if index_exists?(:messages, name: MESSAGE_ACCOUNT_INDEX)
    remove_index :conversations, name: CONVERSATION_THREAD_INDEX if index_exists?(:conversations, name: CONVERSATION_THREAD_INDEX)
    remove_column :conversations, :channel_participant if column_exists?(:conversations, :channel_participant)
    remove_reference :messages, :property, foreign_key: true if column_exists?(:messages, :property_id)
    remove_reference :messages, :account, foreign_key: true if column_exists?(:messages, :account_id)
  end

  private

  def backfill_message_tenant_columns
    execute <<~SQL.squish
      UPDATE messages
      SET property_id = conversations.property_id
      FROM conversations
      WHERE messages.conversation_id = conversations.id
        AND messages.property_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE messages
      SET account_id = properties.account_id
      FROM properties
      WHERE messages.property_id = properties.id
        AND messages.account_id IS NULL
    SQL
  end

  def backfill_conversation_participants
    execute <<~SQL.squish
      UPDATE conversations
      SET channel = COALESCE(NULLIF(channel, ''), 'whatsapp')
      WHERE channel IS NULL OR channel = ''
    SQL

    execute <<~SQL.squish
      UPDATE conversations
      SET channel_participant = guests.phone_number
      FROM guests
      WHERE conversations.guest_id = guests.id
        AND (conversations.channel_participant IS NULL OR conversations.channel_participant = '')
    SQL

    execute <<~SQL.squish
      UPDATE conversations
      SET channel_participant = 'guest:' || guest_id
      WHERE channel_participant IS NULL OR channel_participant = ''
    SQL
  end

  def deduplicate_conversations
    conversation_model = Class.new(ActiveRecord::Base) do
      self.table_name = "conversations"
    end

    message_model = Class.new(ActiveRecord::Base) do
      self.table_name = "messages"
    end

    groups = conversation_model
      .where.not(channel_participant: [nil, ""])
      .to_a
      .group_by { |conversation| [conversation.channel, conversation.channel_participant] }
      .select { |_key, conversations| conversations.size > 1 }

    groups.each_value do |conversations|
      counts = message_model.where(conversation_id: conversations.map(&:id)).group(:conversation_id).count
      canonical = conversations.max_by do |conversation|
        [
          counts.fetch(conversation.id, 0),
          conversation.last_message_at || conversation.updated_at || conversation.created_at,
          conversation.id
        ]
      end
      latest = conversations.max_by { |conversation| [conversation.last_message_at || conversation.updated_at || conversation.created_at, conversation.id] }

      duplicate_ids = conversations.map(&:id) - [canonical.id]
      next if duplicate_ids.blank?

      execute "UPDATE messages SET conversation_id = #{canonical.id} WHERE conversation_id IN (#{duplicate_ids.join(',')})"
      execute "UPDATE alerts SET conversation_id = #{canonical.id} WHERE conversation_id IN (#{duplicate_ids.join(',')})"
      execute "UPDATE guest_requests SET conversation_id = #{canonical.id} WHERE conversation_id IN (#{duplicate_ids.join(',')})"
      execute "UPDATE ai_decision_logs SET conversation_id = #{canonical.id} WHERE conversation_id IN (#{duplicate_ids.join(',')})"
      execute <<~SQL.squish
        UPDATE conversations
        SET property_id = #{latest.property_id},
            guest_id = #{latest.guest_id},
            channel = #{quote(latest.channel)},
            channel_participant = #{quote(latest.channel_participant)},
            last_message_at = (SELECT MAX(created_at) FROM messages WHERE conversation_id = #{canonical.id}),
            updated_at = #{quote(Time.current)}
        WHERE id = #{canonical.id}
      SQL
      execute "DELETE FROM conversations WHERE id IN (#{duplicate_ids.join(',')})"
    end
  end
end
