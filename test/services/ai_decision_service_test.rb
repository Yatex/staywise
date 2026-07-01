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
    assert_includes decision.response_text, "password"
    assert_not decision.escalation_required
    assert_includes decision.evidence.map { |item| item["source_id"] }, "property_fact:wifi_password"
  end

  test "qr property guest without reservation dates receives wifi details in spanish" do
    @guest.update!(check_in_date: nil, checkout_date: nil)
    message = @conversation.messages.create!(sender: "guest", body: "Quisiera saber la red de wifi", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "La red de WiFi es Test WiFi"
    assert_includes decision.response_text, "la contraseña es secret"
    assert_not_includes decision.response_text, "Thanks for your message"
    assert_not decision.escalation_required
  end

  test "answers checkout in spanish with a warm complete sentence" do
    message = @conversation.messages.create!(sender: "guest", body: "¿A qué hora es el checkout?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "El checkout es a las 11:00 AM"
    assert_includes decision.response_text, "Si necesitás salir más tarde"
    assert_not_equal "11:00 AM", decision.response_text
  end

  test "treats checkout as spanish when the surrounding phrase is spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "Y el check out?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "El checkout es a las 11:00 AM"
    assert_not_includes decision.response_text, "Checkout is at"
  end

  test "asks a clarifying question for ambiguous time intent in spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "A que hora puedo ir?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "ask_clarifying_question", decision.outcome
    assert_includes decision.response_text, "check-in"
    assert_includes decision.response_text, "checkout"
    assert_not decision.escalation_required
    assert_nil decision.alert_type
  end

  test "answers check in when guest explicitly asks arrival time in spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "A que hora puedo llegar?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "El check-in es a las 3:00 PM"
    assert_not decision.escalation_required
    assert_equal ["property_fact:check_in_time"], decision.evidence.map { |item| item["source_id"] }
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

  test "matches reusable faq despite shorthand and different wording" do
    faq = @property.faqs.create!(
      question: "Como bajo a la pileta?",
      answer: "Andá al -1 y después subí por la ventana.",
      category: "amenities",
      active: true
    )
    message = @conversation.messages.create!(sender: "guest", body: "Cómo llego q pileta?", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "Andá al -1"
    assert_not decision.escalation_required
    assert_equal ["faq:#{faq.id}"], decision.evidence.map { |item| item["source_id"] }
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

  test "uses fallback decision from non-success ai service response" do
    ENV["AI_SERVICE_URL"] = "https://ai-service.test"
    message = @conversation.messages.create!(sender: "guest", body: "Quisiera saber si hay piscina", channel: "whatsapp")
    response = Struct.new(:code, :body).new(
      "500",
      {
        outcome: "escalate",
        response_text: "Gracias por tu mensaje. Lo estoy consultando con el anfitrión y te responderé en breve.",
        should_reply: true,
        confidence: 0.25,
        evidence: [],
        escalation: { required: true, category: "unknown", urgency: "medium", summary: "El huésped hizo una pregunta que el servicio de IA no pudo responder." },
        proposed_action: nil,
        escalation_required: true,
        alert_type: "unknown_question",
        alert_title: "Pregunta pendiente del anfitrión",
        alert_description: "Quisiera saber si hay piscina",
        suggested_owner_action: "Agregá la respuesta a la guía o FAQ de la propiedad y luego respondé al huésped."
      }.to_json
    )

    original_post = Net::HTTP.method(:post)
    Net::HTTP.define_singleton_method(:post) { |_uri, _body, _headers| response }

    begin
      decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

      assert_equal "escalate", decision.outcome
      assert_equal "unknown_question", decision.alert_type
      assert_includes decision.response_text, "Gracias por tu mensaje"
      assert_not_includes decision.response_text, "Thanks for your message"
    ensure
      Net::HTTP.define_singleton_method(:post, original_post)
    end
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
