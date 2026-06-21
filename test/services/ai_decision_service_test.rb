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

  test "answers from guide block with optional youtube video" do
    @property.knowledge_blocks.create!(
      title: "Smart TV",
      category: "amenities",
      content: "Use HDMI 1 for streaming devices.",
      status: "active",
      youtube_url: "https://www.youtube.com/watch?v=abc123"
    )
    message = @conversation.messages.create!(sender: "guest", body: "How do I use the Smart TV?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_not decision.escalation_required
    assert_includes decision.response_text, "Use HDMI 1"
    assert_includes decision.response_text, "https://www.youtube.com/watch?v=abc123"
  end

  test "escalates approval based late checkout request" do
    message = @conversation.messages.create!(sender: "guest", body: "Can I get late checkout?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert decision.escalation_required
    assert_equal :late_checkout_request, decision.alert_type
    assert_includes decision.response_text, "anfitrión"
  end

  test "unknown property question can become reusable faq knowledge" do
    unknown_message = @conversation.messages.create!(sender: "guest", body: "What color is the front door?", channel: "whatsapp")

    unknown_decision = AI::DecisionService.call(conversation: @conversation, guest_message: unknown_message)

    assert unknown_decision.escalation_required
    assert_equal "unknown_question", unknown_decision.alert_type
    assert_equal "What color is the front door?", unknown_decision.alert_description

    @property.faqs.create!(
      question: "What color is the front door?",
      answer: "The front door is dark green.",
      category: "custom_notes",
      active: true
    )
    answered_message = @conversation.messages.create!(sender: "guest", body: "What color is the front door?", channel: "whatsapp")

    answered_decision = AI::DecisionService.call(conversation: @conversation, guest_message: answered_message)

    assert_not answered_decision.escalation_required
    assert_includes answered_decision.response_text, "dark green"
  end
end
