require "test_helper"

class ConversationsDeduplicatorTest < ActiveSupport::TestCase
  INDEX_NAME = Conversations::Deduplicator::INDEX_NAME

  setup do
    @connection = ActiveRecord::Base.connection
  end

  test "database rejects a second conversation for the same guest and channel" do
    account = Account.create!(name: "Unique Conversations")
    property = account.properties.create!(name: "Unique Apartment")
    guest = account.guests.create!(phone_number: "+15556660001", property: property)
    guest.conversations.create!(property: property, channel: "whatsapp")

    assert_raises ActiveRecord::RecordNotUnique do
      Conversation.insert_all!([
        conversation_attributes(guest: guest, property: property, channel: "whatsapp")
      ])
    end
  end

  test "same phone in different accounts can have separate conversations" do
    account_one = Account.create!(name: "Account One")
    account_two = Account.create!(name: "Account Two")
    property_one = account_one.properties.create!(name: "Apartment One")
    property_two = account_two.properties.create!(name: "Apartment Two")
    guest_one = account_one.guests.create!(phone_number: "+15556660002", property: property_one)
    guest_two = account_two.guests.create!(phone_number: "+15556660002", property: property_two)

    conversation_one = guest_one.conversations.create!(property: property_one, channel: "whatsapp")
    conversation_two = guest_two.conversations.create!(property: property_two, channel: "whatsapp")

    assert_not_equal conversation_one.id, conversation_two.id
  end

  test "deduplicate merges duplicate conversations and is idempotent" do
    without_conversation_unique_index do
      account = Account.create!(name: "Duplicate Conversations")
      old_property = account.properties.create!(name: "Old Property")
      current_property = account.properties.create!(name: "Current Property")
      guest = account.guests.create!(phone_number: "+15556660003", property: old_property)
      older = Time.current - 2.days
      newer = Time.current - 1.hour

      first_id = insert_conversation!(guest: guest, property: old_property, created_at: older, updated_at: older)
      second_id = insert_conversation!(guest: guest, property: current_property, created_at: newer, updated_at: newer)
      first = Conversation.find(first_id)
      second = Conversation.find(second_id)

      first_message = first.messages.create!(sender: "guest", channel: "whatsapp", body: "mensaje uno", metadata: { "MessageSid" => "SM_ONE" })
      first.messages.create!(sender: "ai", channel: "whatsapp", body: "respuesta uno")
      second_message = second.messages.create!(sender: "guest", channel: "whatsapp", body: "mensaje dos", metadata: { "MessageSid" => "SM_TWO" })
      alert = second.alerts.create!(property: current_property, guest: guest, alert_type: "unknown_question", title: "Pregunta", description: "mensaje dos", original_message: second_message)
      request = second.guest_requests.create!(
        account: account,
        property: current_property,
        guest: guest,
        message: second_message,
        guest_phone: guest.phone_number,
        property_name: current_property.display_name,
        category: "food_or_drink",
        title: "Pedido",
        description: "mensaje dos",
        source_channel: "whatsapp"
      )
      log = AIDecisionLog.create!(
        account: account,
        property: current_property,
        guest: guest,
        conversation: second,
        message: second_message,
        original_message: second_message,
        route: "remote_ai",
        decision: "escalate"
      )

      dry_run = Conversations::Deduplicator.new(dry_run: true, logger: nil).call

      assert_equal 1, dry_run.duplicate_group_count
      assert_equal 2, Conversation.where(guest: guest, channel: "whatsapp").count

      result = Conversations::Deduplicator.new(dry_run: false, logger: nil).call
      canonical = Conversation.find(first.id)

      assert_equal 1, result.duplicate_group_count
      assert_equal 1, Conversation.where(guest: guest, channel: "whatsapp").count
      assert_equal current_property, canonical.reload.property
      assert_equal ["mensaje uno", "respuesta uno", "mensaje dos"], canonical.messages.order(:created_at, :id).pluck(:body)
      assert_equal canonical, alert.reload.conversation
      assert_equal canonical, request.reload.conversation
      assert_equal canonical, log.reload.conversation
      assert_equal first_message, canonical.messages.find(first_message.id)

      second_run = Conversations::Deduplicator.new(dry_run: false, logger: nil).call

      assert_equal 0, second_run.duplicate_group_count
      assert_equal 1, Conversation.where(guest: guest, channel: "whatsapp").count
    end
  end

  test "deduplicate removes duplicate provider messages and reassigns references" do
    without_conversation_unique_index do
      account = Account.create!(name: "Duplicate Messages")
      property = account.properties.create!(name: "Message Apartment")
      guest = account.guests.create!(phone_number: "+15556660004", property: property)

      first_id = insert_conversation!(guest: guest, property: property, created_at: 2.days.ago, updated_at: 2.days.ago)
      second_id = insert_conversation!(guest: guest, property: property, created_at: 1.day.ago, updated_at: 1.day.ago)
      first = Conversation.find(first_id)
      second = Conversation.find(second_id)
      canonical_message = first.messages.create!(sender: "guest", channel: "whatsapp", body: "mismo mensaje", metadata: { "MessageSid" => "SM_DUP" })
      duplicate_message = second.messages.create!(sender: "guest", channel: "whatsapp", body: "mismo mensaje", metadata: { "MessageSid" => "SM_DUP" })
      alert = second.alerts.create!(property: property, guest: guest, alert_type: "unknown_question", title: "Duplicada", original_message: duplicate_message)

      result = Conversations::Deduplicator.new(dry_run: false, logger: nil).call

      assert_equal 1, result.moved_counts[:duplicate_messages_removed]
      assert_equal 1, Conversation.where(guest: guest, channel: "whatsapp").count
      assert_equal 1, Message.where(metadata: { "MessageSid" => "SM_DUP" }).count
      assert_equal canonical_message, alert.reload.original_message
    end
  end

  test "create conversation helper reloads existing row on unique race" do
    account = Account.create!(name: "Race Conversations")
    property = account.properties.create!(name: "Race Apartment")
    guest = account.guests.create!(phone_number: "+15556660005", property: property)
    existing = guest.conversations.create!(property: property, channel: "whatsapp")
    handler = Whatsapp::IncomingMessageHandler.new({}, provider: Whatsapp::Providers::NullProvider.new)

    resolved = handler.send(:create_conversation_for!, guest: guest, property: property)

    assert_equal existing, resolved
    assert_equal 1, guest.conversations.where(channel: "whatsapp").count
  end

  private

  def without_conversation_unique_index
    remove_unique_index
    yield
  ensure
    Conversations::Deduplicator.new(dry_run: false, logger: nil).call
    add_unique_index
  end

  def remove_unique_index
    @connection.execute("DROP INDEX IF EXISTS #{@connection.quote_table_name(INDEX_NAME)}")
  end

  def add_unique_index
    return if conversation_unique_index_exists?

    @connection.add_index(:conversations, [:guest_id, :channel], unique: true, name: INDEX_NAME)
  end

  def conversation_unique_index_exists?
    @connection.indexes(:conversations).any? { |index| index.name == INDEX_NAME }
  end

  def insert_conversation!(guest:, property:, created_at:, updated_at:)
    Conversation.insert_all!([
      conversation_attributes(guest: guest, property: property, channel: "whatsapp", created_at: created_at, updated_at: updated_at)
    ], returning: %w[id]).rows.first.first
  end

  def conversation_attributes(guest:, property:, channel:, created_at: Time.current, updated_at: Time.current)
    {
      guest_id: guest.id,
      property_id: property.id,
      channel: channel,
      status: "active",
      ai_enabled: true,
      created_at: created_at,
      updated_at: updated_at
    }
  end
end
