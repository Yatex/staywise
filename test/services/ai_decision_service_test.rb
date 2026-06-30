require "test_helper"

class AiDecisionServiceTest < ActiveSupport::TestCase
  setup do
    @previous_ai_service_url = ENV["AI_SERVICE_URL"]
    ENV["AI_SERVICE_URL"] = nil
    @account = Account.create!(name: "Test Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(
      name: "Test Apartment",
      address: "123 Test Street",
      check_in_time: "3:00 PM",
      checkout_time: "11:00 AM",
      parking_instructions: "Street parking is available.",
      wifi_name: "Test WiFi",
      wifi_password: "secret"
    )
    @guest = @account.guests.create!(
      phone_number: "+15550000001",
      property: @property,
      check_in_date: Date.current,
      checkout_date: Date.current + 2.days
    )
    @conversation = @guest.conversations.create!(property: @property)
  end

  teardown do
    ENV["AI_SERVICE_URL"] = @previous_ai_service_url
  end

  test "answers exact check in time deterministically with evidence" do
    message = @conversation.messages.create!(sender: "guest", body: "What time is check-in?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "3:00 PM"
    assert_not decision.escalation_required
    assert_equal ["property_fact:check_in_time"], decision.evidence.map { |item| item["source_id"] }
  end

  test "answers address deterministically with evidence" do
    message = @conversation.messages.create!(sender: "guest", body: "Can you send the address?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "123 Test Street"
    assert_not decision.escalation_required
    assert_equal ["property_fact:address"], decision.evidence.map { |item| item["source_id"] }
  end

  test "authorized guest can receive wifi details deterministically" do
    message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "Test WiFi"
    assert_includes decision.response_text, "secret"
    assert_not decision.escalation_required
    assert_includes decision.evidence.map { |item| item["source_id"] }, "property_fact:wifi_password"
  end

  test "guest outside reservation window cannot receive wifi details" do
    @guest.update!(check_in_date: Date.current + 10.days, checkout_date: Date.current + 12.days)
    message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "escalate", decision.outcome
    assert decision.escalation_required
    assert_equal "owner_approval_required", decision.alert_type
    assert_not_includes decision.response_text, "secret"
  end

  test "escalates approval based late checkout request" do
    message = @conversation.messages.create!(sender: "guest", body: "Can I get late checkout?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert decision.escalation_required
    assert_equal "late_checkout_request", decision.alert_type
    assert_equal "propose_action", decision.outcome
    assert_includes decision.response_text, "checking this with the host"
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
    assert_equal ["faq:#{@property.faqs.last.id}"], answered_decision.evidence.map { |item| item["source_id"] }
  end

  test "default qr intro asks how to help without alerting owner" do
    message = @conversation.messages.create!(
      sender: "guest",
      body: "Hola, tengo una consulta sobre #{@property.display_name}. #{@property.whatsapp_reference}",
      channel: "whatsapp"
    )

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "ask_clarifying_question", decision.outcome
    assert_not decision.escalation_required
    assert_nil decision.alert_type
    assert_includes decision.response_text, "¿En qué puedo ayudarte?"
  end

  test "guest fallback reply uses guest language while owner alert stays spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "游泳池在哪里？", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert decision.escalation_required
    assert_equal "unknown_question", decision.alert_type
    assert_includes decision.response_text, "房东"
    assert_equal "La pregunta necesita respuesta del anfitrión", decision.alert_title
    assert_equal "Revisá la consulta antes de responder. Si es información reusable, agregala como FAQ o bloque de guía.", decision.suggested_owner_action
    assert_equal "zh", @guest.reload.language
  end

  test "ai reply without evidence is rejected and falls back safely" do
    decision = AI::DecisionResult.from_hash(
      outcome: "reply",
      response_text: "Use HDMI 1.",
      confidence: 0.9,
      evidence: [],
      escalation: { required: false, category: nil, urgency: nil, summary: nil },
      proposed_action: nil
    )
    service_class = Class.new(AI::DecisionService) do
      define_method(:remote_decision) { |_payload| decision }
    end
    service = service_class.new(conversation: @conversation, guest_message: @conversation.messages.create!(sender: "guest", body: "Tell me about the TV", channel: "whatsapp"))

    result = service.call

    assert_equal "escalate", result.outcome
    assert result.escalation_required
    assert_includes result.response_text, "checking this with the host"
  end

  test "ai reply with evidence from another property is rejected" do
    other_property = @account.properties.create!(name: "Other")
    other_faq = other_property.faqs.create!(question: "Where is the gym?", answer: "Other gym", active: true)
    message = @conversation.messages.create!(sender: "guest", body: "Where is the gym?", channel: "whatsapp")
    decision = AI::DecisionResult.from_hash(
      outcome: "reply",
      response_text: "Other gym",
      confidence: 0.9,
      evidence: [{ source_type: "faq", source_id: "faq:#{other_faq.id}", claim: "Gym information" }],
      escalation: { required: false, category: nil, urgency: nil, summary: nil },
      proposed_action: nil
    )
    service_class = Class.new(AI::DecisionService) do
      define_method(:remote_decision) { |_payload| decision }
    end
    service = service_class.new(conversation: @conversation, guest_message: message)

    result = service.call

    assert_equal "escalate", result.outcome
    assert result.escalation_required
  end
end
