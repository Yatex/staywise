require "test_helper"

class AiDecisionServiceTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Test Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(
      name: "Test Apartment",
      wifi_name: "Test WiFi",
      wifi_password: "secret"
    )
    @property.knowledge_blocks.create!(
      title: "WiFi details",
      category: "wifi",
      content: "Network: Test WiFi. Password: secret.",
      status: "active"
    )
    @guest = @account.guests.create!(phone_number: "+15550000001", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
  end

  test "answers from configured property knowledge" do
    message = @conversation.messages.create!(sender: "guest", body: "What is the wifi?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_includes decision.response_text, "Test WiFi"
    assert_not decision.escalation_required
    assert decision.confidence > 0.5
  end

  test "escalates approval based late checkout request" do
    message = @conversation.messages.create!(sender: "guest", body: "Can I get late checkout?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert decision.escalation_required
    assert_equal :late_checkout_request, decision.alert_type
    assert_includes decision.response_text, "host"
  end
end
