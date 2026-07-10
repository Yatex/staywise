require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Conversation Model Stays")
    @property = @account.properties.create!(name: "Conversation Model Property")
    @guest = @account.guests.create!(phone_number: "+15559990000", property: @property)
  end

  test "sets whatsapp participant from guest phone" do
    conversation = @guest.conversations.create!(property: @property, channel: "whatsapp")

    assert_equal "+15559990000", conversation.channel_participant
  end

  test "database prevents duplicate active whatsapp conversations for the same guest thread" do
    @guest.conversations.create!(property: @property, channel: "whatsapp")

    duplicate = Conversation.new(
      guest: @guest,
      property: @property,
      channel: "whatsapp",
      channel_participant: @guest.phone_number,
      status: "active",
      ai_enabled: true
    )

    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end
end
