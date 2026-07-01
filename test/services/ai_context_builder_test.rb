require "test_helper"

class AiContextBuilderTest < ActiveSupport::TestCase
  setup do
    @previous_app_host = ENV["APP_HOST"]
    ENV["APP_HOST"] = "https://aylamanager.test"
    @account = Account.create!(name: "Context Builder")
    @property = @account.properties.create!(name: "Context Apartment")
    @guest = @account.guests.create!(phone_number: "+15550003000", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    @message = @conversation.messages.create!(sender: "guest", body: "Where is the pool?", channel: "whatsapp")
  end

  teardown do
    ENV["APP_HOST"] = @previous_app_host
  end

  test "includes remote tool endpoint details" do
    payload = AI::ContextBuilder.new(conversation: @conversation, guest_message: @message).call

    assert_equal "https://aylamanager.test", payload.dig(:tool_endpoint, :base_url)
    assert_equal @conversation.id, payload.dig(:tool_endpoint, :conversation_id)
    assert_equal @message.id, payload.dig(:tool_endpoint, :message_id)
  end
end
