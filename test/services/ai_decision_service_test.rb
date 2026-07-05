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

  test "accepts ai check in reply with valid evidence" do
    message = @conversation.messages.create!(sender: "guest", body: "What time is check-in?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "Check-in is at 3:00 PM.",
      evidence_ids: ["property.check_in_time"],
      detected_intents: [{ type: "check_in", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "3:00 PM"
    assert_not decision.escalation_required
    assert_equal ["property.check_in_time"], decision.evidence_ids
  end

  test "accepts ai address reply with valid evidence" do
    message = @conversation.messages.create!(sender: "guest", body: "Can you send the address?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "The address is 123 Test Street.",
      evidence_ids: ["property.address"],
      detected_intents: [{ type: "address", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "123 Test Street"
    assert_not decision.escalation_required
    assert_equal ["property.address"], decision.evidence_ids
  end

  test "authorized guest can receive wifi details from ai with evidence" do
    message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "The WiFi network is Test WiFi and the password is secret.",
      used_source_ids: ["sensitive_wifi_name", "sensitive_wifi_password"],
      sensitive_info_used: true,
      detected_intents: [{ type: "wifi", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "Test WiFi"
    assert_includes decision.response_text, "secret"
    assert_includes decision.response_text, "password"
    assert_not decision.escalation_required
    assert_includes decision.used_source_ids, "sensitive_wifi_password"
  end

  test "qr property guest without reservation dates receives wifi details in spanish" do
    @guest.update!(check_in_date: nil, checkout_date: nil)
    message = @conversation.messages.create!(sender: "guest", body: "Quisiera saber la red de wifi", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "La red de WiFi es Test WiFi y la contraseña es secret.",
      used_source_ids: ["sensitive_wifi_name", "sensitive_wifi_password"],
      sensitive_info_used: true,
      detected_intents: [{ type: "wifi", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "La red de WiFi es Test WiFi"
    assert_includes decision.response_text, "la contraseña es secret"
    assert_not_includes decision.response_text, "Thanks for your message"
    assert_not decision.escalation_required
  end

  test "answers checkout in spanish with a warm complete sentence" do
    message = @conversation.messages.create!(sender: "guest", body: "¿A qué hora es el checkout?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "El checkout es a las 11:00 AM. Si necesitás salir más tarde, tiene que confirmarlo el anfitrión.",
      evidence_ids: ["property.check_out_time"],
      detected_intents: [{ type: "checkout", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "El checkout es a las 11:00 AM"
    assert_includes decision.response_text, "Si necesitás salir más tarde"
    assert_not_equal "11:00 AM", decision.response_text
  end

  test "treats checkout as spanish when the surrounding phrase is spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "Y el check out?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "El checkout es a las 11:00 AM.",
      evidence_ids: ["property.check_out_time"],
      detected_intents: [{ type: "checkout", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "El checkout es a las 11:00 AM"
    assert_not_includes decision.response_text, "Checkout is at"
  end

  test "asks a clarifying question for ambiguous time intent in spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "A que hora puedo ir?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_clarification(
      language: "es",
      message_body: "Para ayudarte bien, ¿te referís a la hora de llegada o a la posibilidad de dejar equipaje antes del check-in?",
      detected_intents: [{ type: "ambiguous_time", status: "needs_clarification" }]
    ))

    assert_equal "ask_clarifying_question", decision.outcome
    assert_includes decision.response_text, "check-in"
    assert_includes decision.response_text, "equipaje"
    assert_not decision.escalation_required
    assert_nil decision.alert_type
  end

  test "answers check in when guest explicitly asks arrival time in spanish" do
    message = @conversation.messages.create!(sender: "guest", body: "A que hora puedo llegar?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "El check-in es a las 3:00 PM.",
      evidence_ids: ["property.check_in_time"],
      detected_intents: [{ type: "check_in", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "El check-in es a las 3:00 PM"
    assert_not decision.escalation_required
    assert_equal ["property.check_in_time"], decision.evidence_ids
  end

  test "does not answer check in when guest asks for directions to the building" do
    message = @conversation.messages.create!(sender: "guest", body: "Me pasarias una guía para llegar al edificio?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "La dirección es 123 Test Street.",
      evidence_ids: ["property.address"],
      detected_intents: [{ type: "directions", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "La dirección es"
    assert_includes decision.response_text, "123 Test Street"
    assert_not_includes decision.response_text, "Check-in is at"
    assert_not_includes decision.response_text, "El check-in es"
    assert_equal ["property.address"], decision.evidence_ids
  end

  test "escalates reservation extension requests" do
    message = @conversation.messages.create!(sender: "guest", body: "Puedo extender la reserva", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_action(
      language: "es",
      message_body: "Extender la reserva requiere confirmación del anfitrión. Ya envié tu solicitud.",
      action_type: "request_reservation_extension",
      reason_code: "booking_change",
      detected_intents: [{ type: "reservation_extension", status: "requires_host_approval" }]
    ))

    assert_equal "propose_action", decision.outcome
    assert decision.escalation_required
    assert_equal "owner_approval_required", decision.alert_type
    assert_includes decision.response_text, "requiere confirmación"
  end

  test "guest outside reservation window cannot receive wifi details" do
    @guest.update!(check_in_date: Date.current + 10.days, checkout_date: Date.current + 12.days)
    message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_escalation(
      language: "en",
      message_body: "I cannot share access details until they are authorized for your stay. I have sent your request to the host.",
      reason_code: "access",
      detected_intents: [{ type: "wifi", status: "escalated" }]
    ))

    assert_equal "escalate", decision.outcome
    assert decision.escalation_required
    assert_equal "owner_approval_required", decision.alert_type
    assert_not_includes decision.response_text, "secret"
  end

  test "escalates approval based late checkout request" do
    message = @conversation.messages.create!(sender: "guest", body: "Can I get late checkout?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_action(
      language: "en",
      message_body: "Late checkout depends on availability and requires host confirmation. I have sent your request.",
      action_type: "request_late_checkout",
      reason_code: "booking_change",
      detected_intents: [{ type: "late_checkout", status: "requires_host_approval" }]
    ))

    assert decision.escalation_required
    assert_equal "late_checkout_request", decision.alert_type
    assert_equal "propose_action", decision.outcome
    assert_includes decision.response_text, "requires host confirmation"
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

    answered_decision = run_with_remote_decision(answered_message, ai_reply(
      language: "en",
      message_body: "The front door is dark green.",
      evidence_ids: ["faq.#{@property.faqs.last.id}"],
      detected_intents: [{ type: "faq", status: "answered" }]
    ))

    assert_not answered_decision.escalation_required
    assert_includes answered_decision.response_text, "dark green"
    assert_equal ["faq.#{@property.faqs.last.id}"], answered_decision.evidence_ids
  end

  test "matches reusable faq despite shorthand and different wording" do
    faq = @property.faqs.create!(
      question: "Como bajo a la pileta?",
      answer: "Andá al -1 y después subí por la ventana.",
      category: "amenities",
      active: true
    )
    message = @conversation.messages.create!(sender: "guest", body: "Cómo llego q pileta?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "Andá al -1 y después subí por la ventana.",
      evidence_ids: ["faq.#{faq.id}"],
      detected_intents: [{ type: "faq", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "Andá al -1"
    assert_not decision.escalation_required
    assert_equal ["faq.#{faq.id}"], decision.evidence_ids
  end

  test "rejects direct late checkout request reply even when an faq mentions the policy" do
    faq = @property.faqs.create!(
      question: "Can I request late checkout?",
      answer: "Late checkout depends on availability. Ask the host before confirming.",
      category: "checkout",
      active: true
    )
    message = @conversation.messages.create!(sender: "guest", body: "Puedo hacer más tarde el checkout?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "es",
      message_body: "El late checkout depende de disponibilidad. Lo tenemos que confirmar con el anfitrión antes de aprobarlo.",
      used_source_ids: ["faq_#{faq.id}"],
      detected_intents: [{ type: "faq", status: "answered" }]
    ))

    assert_equal "escalate", decision.outcome
    assert decision.escalation_required
    assert_not_includes decision.response_text, "depende de disponibilidad"
  end

  test "does not use pool directions faq to answer visitor permission question" do
    @property.faqs.create!(
      question: "Como bajo a la pileta?",
      answer: "Andá al -1 y después subí por la ventana.",
      category: "amenities",
      active: true
    )
    message = @conversation.messages.create!(sender: "guest", body: "Quiero saber si puedo invitar gente a la pileta del edificio", channel: "whatsapp")

    decision = AI::DecisionService.call(conversation: @conversation, guest_message: message)

    assert decision.escalation_required
    assert_equal "unknown_question", decision.alert_type
    assert_not_includes decision.response_text, "Andá al -1"
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

  test "ai reply with irrelevant recommendation evidence is rejected" do
    recommendation = @property.recommendations.create!(
      name: "Western Union",
      category: "other",
      description: "Lugar para cambiar dinero a pesos.",
      address: "Scalabrini Ortiz 2354"
    )
    message = @conversation.messages.create!(sender: "guest", body: "Me decís los horarios del lavadero?", channel: "whatsapp")
    decision = AI::DecisionResult.from_hash(
      outcome: "reply",
      response_text: "Te comparto un lugar para cambiar dinero a pesos: Western Union.",
      confidence: 0.9,
      evidence: [{ source_type: "recommendation", source_id: "recommendation:#{recommendation.id}", claim: "Money exchange nearby." }],
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
    assert_not_includes result.response_text, "Western Union"
  end

  test "accepts ai reply using property brain faq source id" do
    faq = @property.faqs.create!(
      question: "How do I use the pool?",
      answer: "Take the elevator to level -1.",
      category: "amenities",
      active: true
    )
    message = @conversation.messages.create!(sender: "guest", body: "How do I use the pool?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "Take the elevator to level -1.",
      used_source_ids: ["faq_#{faq.id}"],
      detected_intents: [{ type: "faq", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_equal ["faq_#{faq.id}"], decision.used_source_ids
    assert_equal ["faq_#{faq.id}"], decision.evidence_ids
  end

  test "accepts approved recommendation through property brain source id" do
    recommendation = @property.recommendations.create!(
      name: "Western Union",
      category: "other",
      description: "Good place to exchange money to pesos.",
      address: "Scalabrini Ortiz 2354"
    )
    message = @conversation.messages.create!(sender: "guest", body: "Where can I exchange money?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "The host recommends Western Union for exchanging money to pesos.",
      used_source_ids: ["recommendation_#{recommendation.id}"],
      detected_intents: [{ type: "recommendation", status: "answered" }]
    ))

    assert_equal "reply", decision.outcome
    assert_includes decision.response_text, "Western Union"
    assert_not decision.escalation_required
  end

  test "guest outside reservation window cannot receive wifi even if ai cites sensitive source" do
    @guest.update!(check_in_date: Date.current + 10.days, checkout_date: Date.current + 12.days)
    message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "The WiFi password is secret.",
      used_source_ids: ["sensitive_wifi_password"],
      sensitive_info_used: true,
      detected_intents: [{ type: "wifi", status: "answered" }]
    ))

    assert_equal "escalate", decision.outcome
    assert decision.escalation_required
    assert_not_includes decision.response_text, "secret"
  end

  test "sensitive reply without sensitive flag is rejected" do
    message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")

    decision = run_with_remote_decision(message, ai_reply(
      language: "en",
      message_body: "The WiFi password is secret.",
      used_source_ids: ["sensitive_wifi_password"],
      sensitive_info_used: false,
      detected_intents: [{ type: "wifi", status: "answered" }]
    ))

    assert_equal "escalate", decision.outcome
    assert decision.escalation_required
    assert_not_includes decision.response_text, "secret"
  end

  private

  def run_with_remote_decision(message, decision_hash)
    decision = AI::DecisionResult.from_hash(decision_hash)
    service_class = Class.new(AI::DecisionService) do
      define_method(:remote_decision) { |_payload| decision }
    end

    service_class.new(conversation: @conversation, guest_message: message).call
  end

  def ai_reply(language:, message_body:, detected_intents:, evidence_ids: nil, used_source_ids: nil, sensitive_info_used: false)
    {
      outcome: "reply",
      language: language,
      message_body: message_body,
      intent_summary: detected_intents.map { |intent| intent[:type] }.join(", "),
      detected_intents: detected_intents,
      evidence_ids: Array(evidence_ids),
      used_source_ids: Array(used_source_ids),
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: false, reason_code: nil, summary_for_host: nil },
      escalation_required: false,
      escalation_reason: nil,
      sensitive_info_used: sensitive_info_used,
      missing_information: [],
      safety_flags: [],
      confidence: 0.95
    }
  end

  def ai_clarification(language:, message_body:, detected_intents:)
    {
      decision: "ask_clarifying_question",
      language: language,
      message_body: message_body,
      intent_summary: detected_intents.map { |intent| intent[:type] }.join(", "),
      detected_intents: detected_intents,
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: false, reason_code: nil, summary_for_host: nil },
      missing_information: ["ambiguous_intent"],
      safety_flags: [],
      confidence: 0.9
    }
  end

  def ai_action(language:, message_body:, action_type:, reason_code:, detected_intents:)
    {
      decision: "propose_action",
      language: language,
      message_body: message_body,
      intent_summary: detected_intents.map { |intent| intent[:type] }.join(", "),
      detected_intents: detected_intents,
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: { type: action_type, payload: {} },
      escalation: { required: true, reason_code: reason_code, summary_for_host: message_body },
      missing_information: [],
      safety_flags: [],
      confidence: 0.9
    }
  end

  def ai_escalation(language:, message_body:, reason_code:, detected_intents:)
    {
      decision: "escalate",
      language: language,
      message_body: message_body,
      intent_summary: detected_intents.map { |intent| intent[:type] }.join(", "),
      detected_intents: detected_intents,
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: true, reason_code: reason_code, summary_for_host: message_body },
      missing_information: [],
      safety_flags: [],
      confidence: 0.9
    }
  end
end
