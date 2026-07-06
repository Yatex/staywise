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
    assert payload.dig(:tool_endpoint, :decision_context_id).present?
    assert_nil payload.dig(:tool_endpoint, :conversation_id)
    assert_nil payload.dig(:tool_endpoint, :message_id)

    resolved = AI::DecisionContext.resolve(payload.dig(:tool_endpoint, :decision_context_id))
    assert_equal @conversation, resolved.fetch(:conversation)
    assert_equal @message, resolved.fetch(:guest_message)
  end

  test "includes complete conversation history in chronological order" do
    @conversation.messages.destroy_all
    bodies = 6.times.map do |index|
      @conversation.messages.create!(
        sender: index.even? ? "guest" : "ai",
        channel: "whatsapp",
        body: "Mensaje #{index + 1}"
      ).body
    end
    latest = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "No gracias, así está bien.")

    payload = AI::ContextBuilder.new(conversation: @conversation, guest_message: latest).call

    assert_equal bodies + [latest.body], payload.fetch(:conversation_history).map { |message| message["body"] || message[:body] }
  end
end
