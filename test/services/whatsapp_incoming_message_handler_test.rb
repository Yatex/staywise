require "test_helper"

class WhatsappIncomingMessageHandlerTest < ActiveSupport::TestCase
  class FailingProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:, media_urls: [])
      false
    end
  end

  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :sent_messages

    def initialize
      @sent_messages = []
    end

    def send_message(to:, body:, media_urls: [])
      @sent_messages << { to: to, body: body, media_urls: media_urls }
      super
    end

    def send_template(to:, template_sid:, variables: {})
      @sent_messages << { to: to, body: variables.values.compact.join(" "), template_sid: template_sid, variables: variables }
      super
    end
  end

  class PersistedBeforeSendProvider < Whatsapp::Providers::BaseProvider
    attr_reader :sent_messages

    def initialize(expected_sender:)
      @expected_sender = expected_sender
      @sent_messages = []
    end

    def send_message(to:, body:, media_urls: [])
      persisted = Message.where(sender: @expected_sender, channel: "whatsapp", body: body).exists?
      raise "outbound message was sent before being persisted" unless persisted

      @sent_messages << { to: to, body: body, media_urls: media_urls }
      DeliveryResult.new(success?: true, provider_message_id: "SM_persisted_first", provider_status: "queued")
    end
  end

  setup do
    @account = Account.create!(name: "Webhook Stays")
    @account.update!(email_alerts_enabled: false)
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Webhook Apartment")
  end

  teardown do
  end

  test "creates one late checkout owner task without alert" do
    @property.update!(address: "Av. Test 123")
    result = with_ai_decision(ai_late_checkout_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000002",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} Can I get late checkout?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    conversation = result.fetch(:conversation)

    assert result.fetch(:replied)
    assert_equal "active", conversation.reload.status
    assert_equal "+15550000002", conversation.guest.phone_number
    assert_equal 2, conversation.messages.count
    assert_nil result.fetch(:alert)
    assert_equal 0, conversation.alerts.count

    guest_request = result.fetch(:guest_request)
    assert_equal "late_checkout", guest_request.category
    assert_equal "open", guest_request.status
    assert_equal "request", guest_request.kind
    assert_equal "+15550000002", guest_request.guest_phone
    assert_equal "Av. Test 123", guest_request.property_address
    assert_equal conversation.messages.where(sender: "guest").last, guest_request.message
    assert_no_match(/approved|aprobado/i, conversation.messages.where(sender: "ai").last.body)
  end

  test "stores failed ai outbound message when whatsapp delivery fails" do
    result = with_ai_decision(ai_late_checkout_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000003",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} Can I get late checkout?"
        },
        provider: FailingProvider.new
      ).call
    end

    conversation = result.fetch(:conversation)

    assert_not result.fetch(:replied)
    assert_equal 2, conversation.messages.count
    assert_equal ["guest", "ai"], conversation.messages.order(:id).pluck(:sender)
    failed_message = conversation.messages.where(sender: "ai").last
    assert_equal "failed", failed_message.metadata["delivery_status"]
    assert_equal "whatsapp_delivery_failed", failed_message.metadata["delivery_error"]
  end

  test "food or drink request creates pedido and sends confirmation" do
    provider = RecordingProvider.new
    @property.update!(address: "Calle Vino 456")

    result = with_ai_decision(ai_guest_request_decision(action_type: "request_food_or_drink", intent_type: "request_food_or_drink", message_body: "Perfecto, le aviso al anfitrión sobre tu pedido y te confirmamos en cuanto tengamos respuesta.")) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000023",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} quiero un vino"
        },
        provider: provider
      ).call
    end

    guest_request = result.fetch(:guest_request)

    assert result.fetch(:replied)
    assert_nil result.fetch(:alert)
    assert_equal 0, result.fetch(:conversation).alerts.count
    assert_equal "food_or_drink", guest_request.category
    assert_equal "open", guest_request.status
    assert_equal "+15550000023", guest_request.guest_phone
    assert_equal "Calle Vino 456", guest_request.property_address
    assert_includes guest_request.description, "quiero un vino"
    assert_includes provider.sent_messages.last.fetch(:body), "le aviso al anfitrión"
  end

  test "guest request is created even when ai still needs details" do
    result = with_ai_decision(ai_guest_request_decision(
      action_type: "none",
      intent_type: "request_food_or_drink",
      message_body: "Perfecto, registro tu pedido. ¿Me confirmás qué vino preferís?",
      intent_status: "needs_clarification"
    )) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000026",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} quiero un vino"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    guest_request = result.fetch(:guest_request)

    assert_nil result.fetch(:alert)
    assert_equal "food_or_drink", guest_request.category
    assert_equal "open", guest_request.status
    assert_equal "15550000026 · Pedido", guest_request.title
  end

  test "later clarification updates existing open pedido without duplicate" do
    from = "whatsapp:+15550000027"
    first = with_ai_decision(ai_guest_request_decision(
      action_type: "none",
      intent_type: "request_food_or_drink",
      message_body: "Perfecto, registro tu pedido. ¿Me confirmás qué vino preferís?",
      intent_status: "needs_clarification"
    )) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} quiero un vino"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_no_difference -> { GuestRequest.count } do
      with_ai_decision(AI::DecisionResult.from_hash(
        action: "create_owner_task",
        owner_task_kind: "request",
        language: "es",
        message: "Perfecto, sumo ese detalle al pedido.",
        task_summary: "Vino tinto",
        answer_confidence: 98,
        evidence_ids: [],
        attachments: []
      )) do
        Whatsapp::IncomingMessageHandler.new(
          {
            "From" => from,
            "To" => "whatsapp:+15550009999",
            "Body" => "tinto por favor"
          },
          provider: Whatsapp::Providers::NullProvider.new
        ).call
      end
    end

    guest_request = first.fetch(:guest_request).reload
    assert_equal 1, guest_request.metadata.fetch("updates").length
    assert_includes guest_request.metadata.fetch("updates").first.fetch("body"), "tinto"
    assert_equal "tinto por favor", guest_request.current_guest_message
    assert_includes guest_request.description, "quiero un vino"
    assert_equal false, guest_request.metadata.fetch("awaiting_guest_clarification")

    assert_difference -> { GuestRequest.count }, 1 do
      with_ai_decision(AI::DecisionResult.from_hash(
        action: "create_owner_task",
        owner_task_kind: "request",
        language: "es",
        message: "Recibí tu nuevo pedido.",
        task_summary: "Pedido no relacionado",
        answer_confidence: 98,
        evidence_ids: [],
        attachments: []
      )) do
        Whatsapp::IncomingMessageHandler.new(
          {
            "From" => from,
            "To" => "whatsapp:+15550009999",
            "Body" => "necesito traslado al aeropuerto"
          },
          provider: Whatsapp::Providers::NullProvider.new
        ).call
      end
    end
  end

  test "extra bed request creates pedido" do
    result = with_ai_decision(ai_guest_request_decision(action_type: "request_extra_bed", intent_type: "request_extra_bed", message_body: "Perfecto, le aviso al anfitrión sobre tu pedido y te confirmamos en cuanto tengamos respuesta.")) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000024",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} necesito una cama extra"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_nil result.fetch(:alert)
    assert_equal "extra_bed", result.fetch(:guest_request).category
    assert_equal "open", result.fetch(:guest_request).status
  end

  test "unanswered inquiry creates one inquiry owner task without alert" do
    result = with_ai_decision(ai_unknown_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000029",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Cuál es el código de la ventana?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_nil result.fetch(:alert)
    assert_equal "inquiry", result.fetch(:guest_request).kind
    assert_equal 1, result.fetch(:conversation).owner_tasks.inquiries.count
    assert_equal 0, result.fetch(:conversation).alerts.count
  end

  test "operational escalation creates alert without owner task" do
    result = with_ai_decision(ai_operational_alert_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000030",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} hay un problema"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_equal "maintenance_issue", result.fetch(:alert).alert_type
    assert_nil result.fetch(:guest_request)
    assert_equal 0, result.fetch(:conversation).owner_tasks.count
  end

  test "reprocessing the same AI action does not duplicate owner task or create alert" do
    guest = @account.guests.create!(phone_number: "+15550000028", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "active", ai_enabled: true)
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Necesito un servicio")
    decision = ai_guest_request_decision(action_type: "request_service", intent_type: "request_service")

    first_request = GuestRequests::Creator.call(conversation: conversation, decision: decision, guest_message: message)
    second_request = GuestRequests::Creator.call(conversation: conversation, decision: decision, guest_message: message)
    first_alert = Alerts::Creator.call(conversation: conversation, decision: decision, owner_whatsapp_provider: Whatsapp::Providers::NullProvider.new)
    second_alert = Alerts::Creator.call(conversation: conversation, decision: decision, owner_whatsapp_provider: Whatsapp::Providers::NullProvider.new)

    assert_equal first_request.id, second_request.id
    assert_nil first_alert
    assert_nil second_alert
    assert_equal 1, conversation.guest_requests.count
    assert_equal 0, conversation.alerts.count
  end

  test "pedido uses relinked property when guest sends a new stay token" do
    new_property = @account.properties.create!(name: "Pedido Property B", address: "Nueva 999")
    from = "whatsapp:+15550000025"
    guest = @account.guests.create!(phone_number: "+15550000025", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "active", ai_enabled: true)

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => from,
        "To" => "whatsapp:+15550009999",
        "Body" => new_property.whatsapp_reference
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    result = with_ai_decision(ai_guest_request_decision(action_type: "request_food_or_drink", intent_type: "request_food_or_drink")) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => "quiero pedir desayuno"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    guest_request = result.fetch(:guest_request)

    assert_equal conversation, result.fetch(:conversation)
    assert_equal new_property, guest_request.property
    assert_equal new_property.display_name, guest_request.property_name
    assert_equal "Nueva 999", guest_request.property_address
    assert_equal new_property, conversation.reload.property
    assert_not_equal @property, guest_request.property
  end

  test "escalated alert links original message and ai trace when available" do
    trace = nil
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      trace = AIDecisionLog.create!(
        account: conversation.property.account,
        property: conversation.property,
        guest: conversation.guest,
        conversation: conversation,
        message: guest_message,
        original_message: guest_message,
        route: "remote_ai",
        decision: "escalate",
        final_outcome: "escalate",
        language: "es",
        detected_intents: [{ "type" => "unknown_question", "status" => "escalated" }],
        payload: { "tools" => [], "evidence" => [] }
      )
      ai_operational_alert_decision
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000015",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Puedo invitar gente a la pileta?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    alert = result.fetch(:alert).reload

    assert_equal result.fetch(:message), alert.original_message
    assert_equal trace, alert.ai_decision_log
    assert_equal "ai_escalation", alert.metadata["source"]
    assert_includes alert.metadata["detected_intents"].map { |intent| intent["type"] || intent[:type] }, "operational_failure"
  end

  test "english emergency phrase creates urgent alert from ai decision" do
    @property.update!(emergency_information: "Call 911 first, then contact the host.")

    result = with_ai_decision(ai_emergency_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000004",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} There is smoke in the apartment, emergency"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    alert = result.fetch(:conversation).alerts.first

    assert result.fetch(:replied)
    assert_equal "emergency", alert.alert_type
    assert_equal "urgent", alert.priority
    assert_includes result.fetch(:conversation).messages.where(sender: "ai").last.body, "911"
  end

  test "spanish emergency phrase creates urgent alert" do
    result = with_ai_decision(ai_emergency_decision(message_body: "Si alguien está en peligro, llamá a emergencias. También aviso al anfitrión.")) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000005",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} Hay una fuga de gas"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    alert = result.fetch(:conversation).alerts.first

    assert result.fetch(:replied)
    assert_equal "emergency", alert.alert_type
    assert_equal "urgent", alert.priority
  end

  test "default qr intro is routed through ai decision service" do
    provider = RecordingProvider.new
    ai_calls = 0
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      assert_equal "routing_init", guest_message.metadata["message_type"]
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "👋 Hola, soy Ayla, tu asistente.\n\n🇪🇸 Escribí en español.\n🇬🇧 Write in English.\n🇧🇷 Escreva em português.",
        intent_summary: "routing welcome",
        detected_intents: [{ type: "routing_init", status: "answered" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000008",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference}"
        },
        provider: provider
      ).call
    end

    conversation = result.fetch(:conversation)

    assert_equal 1, ai_calls
    assert_not result.key?(:routing_init)
    assert result.fetch(:replied)
    assert_equal "reply", result.fetch(:decision).outcome
    assert_nil result.fetch(:alert)
    assert_equal 0, conversation.alerts.count
    assert_equal 1, conversation.messages.where(sender: "ai").count
    assert_equal "routing_init", conversation.messages.where(sender: "guest").first.metadata["message_type"]
    assert_includes provider.sent_messages.last.fetch(:body), "Hola, soy Ayla"
    assert_includes provider.sent_messages.last.fetch(:body), "Write in English"
    assert_includes provider.sent_messages.last.fetch(:body), "Escreva em português"
    assert_not_includes provider.sent_messages.last.fetch(:body), "tengo una consulta"
    assert_not_includes provider.sent_messages.last.fetch(:body), "dueño de la propiedad"
  end

  test "spanish greeting reaches ai service and replies in spanish" do
    assert_greeting_routes_to_ai(
      body: "#{@property.whatsapp_reference} Buenas",
      expected_reply: "Buenas, ¿en qué puedo ayudarte?",
      expected_language: "es"
    )
  end

  test "english greeting reaches ai service and replies in english" do
    assert_greeting_routes_to_ai(
      body: "#{@property.whatsapp_reference} Hi",
      expected_reply: "Hi, how can I help?",
      expected_language: "en"
    )
  end

  test "portuguese greeting reaches ai service and replies in portuguese" do
    assert_greeting_routes_to_ai(
      body: "#{@property.whatsapp_reference} Oi",
      expected_reply: "Oi, como posso ajudar?",
      expected_language: "pt"
    )
  end

  test "guest follow up after qr intro stays in same conversation and answers check in" do
    @property.update!(check_in_time: "15:00")
    from = "whatsapp:+15550000018"
    ai_calls = 0

    intro_result = nil
    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "Hola, soy Ayla.",
        intent_summary: "routing welcome",
        detected_intents: [{ type: "routing_init", status: "answered" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      intro_result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference}"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end
    conversation = intro_result.fetch(:conversation)

    follow_up_result = nil
    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "El check-in es a las 15:00.",
        intent_summary: "check in",
        detected_intents: [{ type: "check_in", status: "answered" }],
        evidence_ids: ["property.check_in_time"],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false, reason_code: nil, summary_for_host: nil },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      follow_up_result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => "a que hora es el check in"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_equal conversation, follow_up_result.fetch(:conversation)
    assert_equal 1, ai_calls
    assert_equal 4, conversation.reload.messages.count
    assert_includes conversation.messages.where(sender: "guest").last.body, "check in"
    assert_includes conversation.messages.where(sender: "ai").last.body, "El check-in es a las 15:00"
    assert_nil follow_up_result.fetch(:alert)
  end

  test "new ayla stay token relinks existing whatsapp conversation to the new property" do
    @property.update!(wifi_name: "Old WiFi", wifi_password: "OldSecret")
    new_property = @account.properties.create!(
      name: "New Stay",
      wifi_name: "New WiFi",
      wifi_password: "NewSecret"
    )
    from = "whatsapp:+15550000022"
    guest = @account.guests.create!(
      phone_number: "+15550000022",
      property: @property,
      check_in_date: Date.current,
      checkout_date: Date.current + 2.days
    )
    conversation = guest.conversations.create!(property: @property, status: "active", ai_enabled: true)
    conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "wifi?")

    relink_result = with_ai_decision(AI::DecisionResult.from_hash(
      decision: "no_reply",
      language: "es",
      message_body: nil,
      intent_summary: "routing",
      detected_intents: [{ type: "routing_init", status: "handled" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: false },
      missing_information: [],
      safety_flags: [],
      should_reply: false,
      confidence: 0.9
    )) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => new_property.whatsapp_reference
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_equal "no_reply", relink_result.fetch(:decision).outcome
    assert_equal conversation, relink_result.fetch(:conversation)
    assert_equal new_property, conversation.reload.property
    assert_equal new_property, guest.reload.property
    assert_equal 1, guest.conversations.count
    routing_message = conversation.messages.where(sender: "guest").order(:id).last
    assert_equal true, routing_message.metadata["token_detected"]
    assert_equal true, routing_message.metadata["relinked"]
    assert_equal @property.id, routing_message.metadata["previous_property_id"]
    assert_equal new_property.id, routing_message.metadata["new_property_id"]

    registry = AI::SourceRegistry.new(conversation: conversation.reload)
    access_info = registry.sensitive_access_info(guest_message: "wifi?")
    values = access_info.fetch(:sources).map { |source| source["value"] || source["content"] }
    assert_includes values, "New WiFi"
    assert_includes values, "NewSecret"
    assert_not_includes values, "Old WiFi"
    assert_not_includes values, "OldSecret"

    ai_calls = 0
    follow_up_result = nil
    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      assert_equal new_property, conversation.property
      AIDecisionLog.create!(
        account: conversation.property.account,
        property: conversation.property,
        guest: conversation.guest,
        conversation: conversation,
        message: guest_message,
        original_message: guest_message,
        route: "remote_ai",
        decision: "reply",
        final_outcome: "reply",
        language: "es",
        detected_intents: [{ "type" => "wifi", "status" => "answered" }],
        evidence_ids: ["property.wifi_name", "property.wifi_password"],
        payload: {
          "tools" => ["sensitive_access_info"],
          "evidence" => [
            { "evidence_id" => "property.wifi_name", "value" => "New WiFi" },
            { "evidence_id" => "property.wifi_password", "value" => "NewSecret" }
          ]
        }
      )
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "La red de WiFi es New WiFi y la contraseña es NewSecret.",
        intent_summary: "wifi",
        detected_intents: [{ type: "wifi", status: "answered" }],
        evidence_ids: ["property.wifi_name", "property.wifi_password"],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false, reason_code: nil, summary_for_host: nil },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      follow_up_result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => "wifi?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert_equal conversation, follow_up_result.fetch(:conversation)
    assert_equal 1, ai_calls
    assert_nil follow_up_result.fetch(:alert)
    ai_message = conversation.messages.where(sender: "ai").last
    assert_includes ai_message.body, "New WiFi"
    assert_includes ai_message.body, "NewSecret"
    assert_not_includes ai_message.body, "Old WiFi"
    trace = AIDecisionLog.order(:id).last
    assert_equal new_property, trace.property
    assert_not_includes trace.payload.to_json, "Old WiFi"
    assert_equal conversation.id, trace.conversation_id
  end

  test "new token from another account reuses the whatsapp thread and segments messages by tenant" do
    other_account = Account.create!(name: "Other Webhook Stays")
    other_account.update!(email_alerts_enabled: false)
    other_account.subscriptions.create!(plan: "growth", status: "trialing")
    other_property = other_account.properties.create!(name: "Other Account Property", wifi_name: "Other WiFi", wifi_password: "OtherSecret")
    from = "whatsapp:+15550000045"
    old_guest = @account.guests.create!(phone_number: "+15550000045", property: @property)
    conversation = old_guest.conversations.create!(property: @property, status: "active", ai_enabled: true)
    old_message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "old property question")

    relink_result = with_ai_decision(AI::DecisionResult.from_hash(
      decision: "no_reply",
      language: "es",
      message_body: nil,
      intent_summary: "routing",
      detected_intents: [{ type: "routing_init", status: "handled" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: false },
      missing_information: [],
      safety_flags: [],
      should_reply: false,
      confidence: 0.9
    )) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => other_property.whatsapp_reference
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    conversation.reload
    new_guest = other_account.guests.find_by!(phone_number: "+15550000045")

    assert_equal conversation, relink_result.fetch(:conversation)
    assert_equal other_property, conversation.property
    assert_equal new_guest, conversation.guest
    assert_equal @account, old_message.reload.account
    assert_equal @property, old_message.property

    follow_up_result = nil
    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      assert_equal other_property, conversation.property
      assert_equal other_account, guest_message.account
      assert_equal other_property, guest_message.property
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "La red de WiFi es Other WiFi.",
        intent_summary: "wifi",
        detected_intents: [{ type: "wifi", status: "answered" }],
        evidence_ids: ["property.wifi_name"],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      follow_up_result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => from,
          "To" => "whatsapp:+15550009999",
          "Body" => "wifi?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    new_guest_message = follow_up_result.fetch(:message)

    assert_equal conversation, follow_up_result.fetch(:conversation)
    assert_equal other_account, new_guest_message.account
    assert_equal other_property, new_guest_message.property
    assert_equal 1, Conversation.where(channel: "whatsapp", channel_participant: "+15550000045").count
    assert_equal [@account.id, other_account.id], conversation.messages.order(:id).pluck(:account_id).uniq
  end

  test "deleted property token is not reused and does not fall back to an existing conversation" do
    deleted_property = @account.properties.create!(name: "Deleted Stay", wifi_name: "Deleted WiFi", wifi_password: "DeletedSecret")
    active_property = @account.properties.create!(name: "Active Stay", wifi_name: "Active WiFi", wifi_password: "ActiveSecret")
    deleted_reference = deleted_property.whatsapp_reference
    deleted_property.soft_delete!
    from = "whatsapp:+15550000044"
    guest = @account.guests.create!(phone_number: "+15550000044", property: active_property)
    conversation = guest.conversations.create!(property: active_property, status: "active", ai_enabled: true)
    conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "wifi?")

    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => from,
        "To" => "whatsapp:+15550009999",
        "Body" => deleted_reference
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_not result.fetch(:replied)
    assert_equal "missing_property_context", result.fetch(:error)
    assert_nil result.fetch(:conversation)
    assert_equal active_property, conversation.reload.property
    assert_equal 1, conversation.messages.count
    assert_equal active_property, guest.reload.property
    assert_equal deleted_property, Property.with_deleted.find(deleted_property.id)
    assert_nil Property.find_by(id: deleted_property.id)
  end

  test "ai reply is persisted before whatsapp delivery is attempted" do
    provider = PersistedBeforeSendProvider.new(expected_sender: "ai")
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "El check-in es a las 15:00.",
        intent_summary: "check in",
        detected_intents: [{ type: "check_in", status: "answered" }],
        evidence_ids: ["property.check_in_time"],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false, reason_code: nil, summary_for_host: nil },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000019",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} a que hora es el check in"
        },
        provider: provider
      ).call
    end

    message = result.fetch(:conversation).messages.where(sender: "ai").last

    assert result.fetch(:replied)
    assert_includes message.body, "El check-in es a las 15:00."
    assert_equal "queued", message.metadata["delivery_status"]
    assert_equal "SM_persisted_first", message.metadata["provider_message_id"]
  end

  test "ambiguous stay question goes through ai and persists clarification" do
    ai_calls = 0
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      assert_includes guest_message.body, "hora puedo ir"
      AI::DecisionResult.from_hash(
        decision: "ask_clarifying_question",
        language: "es",
        message_body: "¿Te referís al horario de check-in para llegar, o a otra cosa como dejar equipaje antes?",
        intent_summary: "ambiguous arrival time",
        detected_intents: [{ type: "ambiguous_time", status: "needs_clarification" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false, reason_code: nil, summary_for_host: nil },
        missing_information: ["ambiguous_intent"],
        safety_flags: [],
        confidence: 0.9
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000019",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} a que hora puedo ir al depto?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    conversation = result.fetch(:conversation)

    assert_equal 1, ai_calls
    assert_nil result.fetch(:alert)
    assert_equal "active", conversation.reload.status
    ai_message = conversation.messages.where(sender: "ai").last
    assert_includes ai_message.body, "check-in"
    assert_includes ai_message.body, "equipaje"
  end

  test "guest closure after ai offer reaches ai and replies naturally without creating alert" do
    provider = RecordingProvider.new
    guest = @account.guests.create!(phone_number: "+15550000020", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "active", ai_enabled: true)
    conversation.messages.create!(
      sender: "ai",
      channel: "whatsapp",
      body: "El checkout es a las 11:00. Si necesitás salir más tarde, puedo consultarlo con el anfitrión."
    )

    ai_calls = 0
    result = nil
    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      assert_equal "No gracias, así está bien.", guest_message.body
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "Perfecto, cualquier cosa escribime.",
        intent_summary: "closure",
        detected_intents: [{ type: "conversational_closure", status: "answered" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000020",
          "To" => "whatsapp:+15550009999",
          "Body" => "No gracias, así está bien."
        },
        provider: provider
      ).call
    end

    assert_equal conversation, result.fetch(:conversation)
    assert_equal 1, ai_calls
    assert result.fetch(:replied)
    assert_nil result.fetch(:alert)
    assert_equal "active", conversation.reload.status
    assert_equal 0, conversation.alerts.count
    assert_equal ["ai", "guest", "ai"], conversation.messages.order(:id).pluck(:sender)
    assert_equal 1, provider.sent_messages.size
    assert_equal "Perfecto, cualquier cosa escribime.", provider.sent_messages.last.fetch(:body)
  end

  test "guest greeting reaches ai and replies naturally without creating alert" do
    provider = RecordingProvider.new
    guest = @account.guests.create!(phone_number: "+15550000021", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "active", ai_enabled: true)

    ai_calls = 0
    result = nil
    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      assert_equal "hola buenas tardes", guest_message.body
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "Hola, buenas tardes. ¿En qué puedo ayudarte?",
        intent_summary: "greeting",
        detected_intents: [{ type: "greeting", status: "answered" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000021",
          "To" => "whatsapp:+15550009999",
          "Body" => "hola buenas tardes"
        },
        provider: provider
      ).call
    end

    assert_equal conversation, result.fetch(:conversation)
    assert_equal 1, ai_calls
    assert result.fetch(:replied)
    assert_nil result.fetch(:alert)
    assert_equal 0, conversation.alerts.count
    assert_equal ["guest", "ai"], conversation.messages.order(:id).pluck(:sender)
    assert_equal 1, provider.sent_messages.size
    assert_includes provider.sent_messages.last.fetch(:body), "Hola, buenas tardes"
    assert_no_match(/address|check_in|parking|property\./i, provider.sent_messages.last.fetch(:body))
  end

  test "rails does not append owner disclosure to ai answer" do
    @property.update!(checkout_time: "11:00")

    result = with_ai_decision(ai_checkout_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000009",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} Y el check out?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    body = result.fetch(:conversation).messages.where(sender: "ai").last.body

    assert result.fetch(:replied)
    assert_includes body, "El checkout es a las 11:00"
    assert_not_includes body, "este chat está compartido con el dueño de la propiedad"
  end

  test "rails does not append owner disclosure after routing welcome" do
    @property.update!(checkout_time: "11:00")
    phone_number = "whatsapp:+15550000010"

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => phone_number,
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference}"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    result = with_ai_decision(ai_checkout_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => phone_number,
          "To" => "whatsapp:+15550009999",
          "Body" => "Y el check out?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    body = result.fetch(:conversation).messages.where(sender: "ai").last.body

    assert_includes body, "El checkout es a las 11:00"
    assert_not_includes body, "este chat está compartido con el dueño de la propiedad"
  end

  test "asks unknown guests to scan property qr instead of using a default property" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000006",
        "To" => "whatsapp:+15550009999",
        "Body" => "What is the wifi password?"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_not result.fetch(:replied)
    assert_equal "missing_property_context", result.fetch(:error)
    assert_nil result.fetch(:conversation)
    assert_equal 0, Conversation.count
    assert_equal 0, Message.count
  end

  test "does not resolve property from enumerable numeric id reference" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000011",
        "To" => "whatsapp:+15550009999",
        "Body" => "Ayla property ##{@property.id} What is the wifi password?"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_not result.fetch(:replied)
    assert_equal "missing_property_context", result.fetch(:error)
    assert_nil result.fetch(:conversation)
    assert_equal 0, Conversation.count
    assert_equal 0, Message.count
  end

  test "routes returning guest without qr to their previous property" do
    guest = @account.guests.create!(phone_number: "+15550000007", property: @property)
    guest.conversations.create!(property: @property, status: "active", ai_enabled: true)

    result = with_ai_decision(ai_late_checkout_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000007",
          "To" => "whatsapp:+15550009999",
          "Body" => "Can I get late checkout?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    assert result.fetch(:replied)
    assert_equal @property, result.fetch(:conversation).property
    assert_nil result.fetch(:alert)
    assert_equal "late_checkout", result.fetch(:guest_request).category
    assert_equal @property, result.fetch(:guest_request).property
  end

  test "new alert sends owner notification without opening an active reply session" do
    previous_template_sid = ENV["TWILIO_OWNER_ESCALATION_TEMPLATE_SID"]
    ENV["TWILIO_OWNER_ESCALATION_TEMPLATE_SID"] = nil
    @account.update!(owner_whatsapp_number: "+15559990000", owner_whatsapp_escalations_enabled: true)
    provider = RecordingProvider.new

    guest_result = with_ai_decision(ai_operational_alert_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000012",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Puedo invitar gente a la pileta?"
        },
        provider: provider
      ).call
    end

    alert = guest_result.fetch(:alert)
    session = @account.owner_whatsapp_sessions.find_by!(alert: alert)
    assert_equal "queued", session.state
    assert_equal "open", alert.reload.status
    owner_notice = provider.sent_messages.find { |message| message.fetch(:to) == "+15559990000" }
    assert_includes owner_notice.fetch(:body), "Nueva alerta de huésped en #{@property.display_name}"
    assert_includes owner_notice.fetch(:body), "Respondé ALERTAS"
    assert_equal "owner_alert_notification_sent", session.metadata["events"].last["type"]
  ensure
    ENV["TWILIO_OWNER_ESCALATION_TEMPLATE_SID"] = previous_template_sid
  end

  test "owner can list select and answer an alert by whatsapp" do
    @account.update!(owner_whatsapp_number: "+15559990000", owner_whatsapp_escalations_enabled: true)
    provider = RecordingProvider.new

    guest_result = with_ai_decision(ai_operational_alert_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000012",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Puedo invitar gente a la pileta?"
        },
        provider: provider
      ).call
    end

    alert = guest_result.fetch(:alert)
    session = @account.owner_whatsapp_sessions.find_by!(alert: alert)

    list_result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990000",
        "To" => "whatsapp:+15550009999",
        "Body" => "ALERTAS"
      },
      provider: provider
    ).call

    assert list_result.fetch(:inbox)
    assert_includes provider.sent_messages.last.fetch(:body), "Alertas abiertas:"
    assert_includes provider.sent_messages.last.fetch(:body), "1. 15550000012"
    assert_includes provider.sent_messages.last.fetch(:body), "Se produjo un problema operativo"
    assert_equal 1, session.reload.metadata["last_listed_position"]

    detail_result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990000",
        "To" => "whatsapp:+15550009999",
        "Body" => "1"
      },
      provider: provider
    ).call

    assert detail_result.fetch(:selected)
    assert_equal "awaiting_answer", session.reload.state
    assert_equal "open", alert.reload.status
    assert_includes provider.sent_messages.last.fetch(:body), "Último mensaje del huésped:"

    answer_result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990000",
        "To" => "whatsapp:+15550009999",
        "Body" => "No se pueden invitar personas a la pileta."
      },
      provider: provider
    ).call

    assert answer_result.fetch(:owner_message)
    assert_equal "resolved", alert.reload.status
    assert_equal "resolved", session.reload.state
    assert_includes guest_result.fetch(:conversation).messages.where(sender: "owner").last.body, "No se pueden invitar"
    suggestion = @property.faqs.last
    assert_equal "Se produjo un problema operativo que requiere atención.", suggestion.question
    assert_equal "No se pueden invitar personas a la pileta.", suggestion.answer
    assert_equal "pending_review", suggestion.status
    assert_not suggestion.active?
    assert_equal "owner_answer", suggestion.source_type
    assert_equal alert, suggestion.source_alert
    assert_equal guest_result.fetch(:conversation).messages.where(sender: "owner").last, suggestion.source_message
  end

  test "owner answer to missing sensitive information stores encrypted datum instead of faq" do
    owner_phone = "+15559990007"
    @account.update!(owner_whatsapp_number: owner_phone, owner_whatsapp_escalations_enabled: true)
    guest = @account.guests.create!(phone_number: "+15550000128", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "escalated")
    original_message = conversation.messages.create!(
      sender: "guest",
      channel: "whatsapp",
      body: "Cuál es la contraseña de la caja fuerte?"
    )
    alert = conversation.alerts.create!(
      property: @property,
      guest: guest,
      original_message: original_message,
      alert_type: "missing_sensitive_information",
      title: "Falta información · Código de caja fuerte",
      description: "Cuál es la contraseña de la caja fuerte?",
      status: "open",
      metadata: {
        "requested_sensitive_type" => "property.safe_code",
        "missing_information" => ["property.safe_code"]
      }
    )
    @account.owner_whatsapp_sessions.create!(alert: alert, state: "awaiting_answer")
    provider = RecordingProvider.new

    assert_no_difference -> { @property.faqs.count } do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:#{owner_phone}",
          "To" => "whatsapp:+15550009999",
          "Body" => "SAFE-7788"
        },
        provider: provider
      ).call
    end

    datum = @property.sensitive_data.find_by!(kind: "safe_code")
    assert_equal "SAFE-7788", datum.value
    assert_equal alert, datum.source_alert
    assert_equal "resolved", alert.reload.status
    assert_equal 1, conversation.messages.where(sender: "owner").count
  end

  test "owner whatsapp translates guest question to owner language and owner answer back to guest language" do
    @account.update!(
      ai_preferred_language: "es",
      owner_whatsapp_number: "+15559990003",
      owner_whatsapp_escalations_enabled: true
    )
    provider = RecordingProvider.new
    translations = {
      "Можно пригласить людей в бассейн?" => "¿Puedo invitar gente a la pileta?",
      "No se pueden invitar personas a la pileta." => "Нельзя приглашать людей в бассейн."
    }

    AI::Translator.stub(:call, ->(text:, **) { translations.fetch(text, text) }) do
      guest_result = with_ai_decision(ai_operational_alert_decision(language: "ru", guest_ack: "Спасибо за сообщение. Я уточню это у хозяина и скоро отвечу.")) do
        Whatsapp::IncomingMessageHandler.new(
          {
            "From" => "whatsapp:+15550000013",
            "To" => "whatsapp:+15550009999",
            "Body" => "#{@property.whatsapp_reference} Можно пригласить людей в бассейн?"
          },
          provider: provider
        ).call
      end

      alert = guest_result.fetch(:alert)
      session = @account.owner_whatsapp_sessions.find_by!(alert: alert)

      assert_equal "Se produjo un problema operativo que requiere atención.", alert.description

      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15559990003",
          "To" => "whatsapp:+15550009999",
          "Body" => "ALERTAS"
        },
        provider: provider
      ).call

      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15559990003",
          "To" => "whatsapp:+15550009999",
          "Body" => "1"
        },
        provider: provider
      ).call

      assert_includes provider.sent_messages.last.fetch(:body), "Se produjo un problema operativo"

      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15559990003",
          "To" => "whatsapp:+15550009999",
          "Body" => "No se pueden invitar personas a la pileta."
        },
        provider: provider
      ).call

      owner_message = guest_result.fetch(:conversation).messages.where(sender: "owner").last
      assert_equal "Нельзя приглашать людей в бассейн.", owner_message.body
      assert_equal "No se pueden invitar personas a la pileta.", owner_message.metadata["original_owner_body"]
      suggestion = @property.faqs.last
      assert_equal "Se produjo un problema operativo que requiere atención.", suggestion.question
      assert_equal "No se pueden invitar personas a la pileta.", suggestion.answer
      assert_equal "pending_review", suggestion.status
      assert_not suggestion.active?
      assert_equal "owner_answer", suggestion.source_type
      assert_equal "resolved", session.reload.state
    end
  end

  test "owner answer creates pending faq suggestion that becomes usable after approval" do
    @account.update!(owner_whatsapp_number: "+15559990007", owner_whatsapp_escalations_enabled: true)
    provider = RecordingProvider.new

    guest_result = with_ai_decision(ai_operational_alert_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000014",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Puedo invitar gente a la pileta?"
        },
        provider: provider
      ).call
    end

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990007",
        "To" => "whatsapp:+15550009999",
        "Body" => "ALERTAS"
      },
      provider: provider
    ).call

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990007",
        "To" => "whatsapp:+15550009999",
        "Body" => "1"
      },
      provider: provider
    ).call

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990007",
        "To" => "whatsapp:+15550009999",
        "Body" => "No se pueden invitar personas a la pileta."
      },
      provider: provider
    ).call

    suggestion = @property.faqs.last
    assert_equal "pending_review", suggestion.status
    assert_not suggestion.active?

    registry = AI::SourceRegistry.new(conversation: guest_result.fetch(:conversation))
    assert_empty registry.search_property_knowledge(query: "puedo invitar amigos a la pileta?").select { |source| source["evidence_id"] == "faq.#{suggestion.id}" }

    suggestion.update!(status: "approved", active: true)
    approved_sources = registry.search_property_knowledge(query: "puedo invitar amigos a la pileta?")

    assert_includes approved_sources.map { |source| source["evidence_id"] }, "faq.#{suggestion.id}"
  end

  test "owner whatsapp lists multiple alerts and only answers the selected one" do
    @account.update!(owner_whatsapp_number: "+15559990001", owner_whatsapp_escalations_enabled: true)
    property_two = @account.properties.create!(name: "Second Apartment")
    guest_one = @account.guests.create!(phone_number: "+15550000101", property: @property)
    guest_two = @account.guests.create!(phone_number: "+15550000102", property: property_two)
    conversation_one = guest_one.conversations.create!(property: @property)
    conversation_two = guest_two.conversations.create!(property: property_two)
    alert_one = conversation_one.alerts.create!(property: @property, guest: guest_one, alert_type: "unknown_question", title: "Question one", description: "Question one")
    alert_two = conversation_two.alerts.create!(property: property_two, guest: guest_two, alert_type: "unknown_question", title: "Question two", description: "Question two")
    provider = RecordingProvider.new

    first = Whatsapp::OwnerEscalationNotifier.call(alert: alert_one, provider: provider)
    second = Whatsapp::OwnerEscalationNotifier.call(alert: alert_two, provider: provider)

    assert first.sent?
    assert second.sent?
    assert_equal "queued", first.session.reload.state
    assert_equal "queued", second.session.reload.state

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990001",
        "To" => "whatsapp:+15550009999",
        "Body" => "ALERTAS"
      },
      provider: provider
    ).call

    list_body = provider.sent_messages.last.fetch(:body)
    assert_includes list_body, "1. 15550000101"
    assert_includes list_body, "2. 15550000102"

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990001",
        "To" => "whatsapp:+15550009999",
        "Body" => "2"
      },
      provider: provider
    ).call

    assert_equal "queued", first.session.reload.state
    assert_equal "awaiting_answer", second.session.reload.state

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990001",
        "To" => "whatsapp:+15550009999",
        "Body" => "La respuesta es para la segunda propiedad."
      },
      provider: provider
    ).call

    assert_equal 0, conversation_one.messages.where(sender: "owner").count
    assert_equal 1, conversation_two.messages.where(sender: "owner").count
    assert_equal "open", alert_one.reload.status
    assert_equal "resolved", alert_two.reload.status
  end

  test "owner whatsapp numeric selection requires an open alert from the inbox" do
    @account.update!(owner_whatsapp_number: "+15559990006", owner_whatsapp_escalations_enabled: true)
    guest = @account.guests.create!(phone_number: "+15550000123", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "escalated")
    alert = conversation.alerts.create!(
      property: @property,
      guest: guest,
      alert_type: "unknown_question",
      title: "Question one",
      description: "Question one",
      status: "open"
    )
    session = @account.owner_whatsapp_sessions.create!(alert: alert, state: "queued")

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990006",
        "To" => "whatsapp:+15550009999",
        "Body" => "1"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_equal "awaiting_answer", session.reload.state

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990006",
        "To" => "whatsapp:+15550009999",
        "Body" => "2"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_equal "awaiting_answer", session.reload.state
  end

  test "owner whatsapp inbox lists alerts across accounts when the same owner phone is reused" do
    owner_phone = "+15559990002"
    @account.update!(owner_whatsapp_number: owner_phone, owner_whatsapp_escalations_enabled: true)
    other_account = Account.create!(name: "Other Owner Account", owner_whatsapp_number: owner_phone, owner_whatsapp_escalations_enabled: true)
    other_property = other_account.properties.create!(name: "Other Apartment")
    guest_one = @account.guests.create!(phone_number: "+15550000111", property: @property)
    guest_two = other_account.guests.create!(phone_number: "+15550000112", property: other_property)
    conversation_one = guest_one.conversations.create!(property: @property)
    conversation_two = guest_two.conversations.create!(property: other_property)
    alert_one = conversation_one.alerts.create!(property: @property, guest: guest_one, alert_type: "unknown_question", title: "First", description: "First")
    alert_two = conversation_two.alerts.create!(property: other_property, guest: guest_two, alert_type: "unknown_question", title: "Second", description: "Second")
    provider = RecordingProvider.new

    first = Whatsapp::OwnerEscalationNotifier.call(alert: alert_one, provider: provider)
    second = Whatsapp::OwnerEscalationNotifier.call(alert: alert_two, provider: provider)

    assert first.sent?
    assert second.sent?
    assert_equal "queued", first.session.reload.state
    assert_equal "queued", second.session.reload.state

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{owner_phone}",
        "To" => "whatsapp:+15550009999",
        "Body" => "ALERTAS"
      },
      provider: provider
    ).call

    body = provider.sent_messages.last.fetch(:body)
    assert_includes body, "Webhook Apartment"
    assert_includes body, "Other Apartment"
  end

  test "owner analytics only runs with explicit ayla trigger while an alert is selected" do
    owner_phone = "+15559990004"
    @account.update!(owner_whatsapp_number: owner_phone, owner_whatsapp_escalations_enabled: true)
    guest = @account.guests.create!(phone_number: "+15550000121", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "escalated")
    conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Puedo invitar gente a la pileta?")
    alert = conversation.alerts.create!(
      property: @property,
      guest: guest,
      alert_type: "unknown_question",
      title: "Pregunta pendiente",
      description: "¿Puedo invitar gente a la pileta?",
      status: "open"
    )
    session = @account.owner_whatsapp_sessions.create!(alert: alert, state: "awaiting_answer")
    provider = RecordingProvider.new

    non_trigger_result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{owner_phone}",
        "To" => "whatsapp:+15550009999",
        "Body" => "pendientes"
      },
      provider: provider
    ).call

    assert_not non_trigger_result[:owner_assistant]
    assert_equal "resolved", alert.reload.status
    assert_equal "resolved", session.reload.state
    assert_equal 1, conversation.messages.where(sender: "owner").count

    alert.update!(status: "open")
    session.update!(state: "awaiting_answer", resolved_at: nil)

    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{owner_phone}",
        "To" => "whatsapp:+15550009999",
        "Body" => "Ayla stats"
      },
      provider: provider
    ).call

    assert result.fetch(:owner_assistant)
    assert_equal "awaiting_answer", session.reload.state
    assert_equal 1, conversation.messages.where(sender: "owner").count
    assert_includes provider.sent_messages.last.fetch(:body), "Resumen de Ayla"
    assert_includes provider.sent_messages.last.fetch(:body), "Consultas de huéspedes: 1"
    assert_includes provider.sent_messages.last.fetch(:body), "Alertas creadas: 1"
    assert_includes provider.sent_messages.last.fetch(:body), "Pendientes ahora:"
  end

  test "owner assistant can list pending alerts with explicit trigger" do
    owner_phone = "+15559990005"
    @account.update!(owner_whatsapp_number: owner_phone, owner_whatsapp_escalations_enabled: true)
    guest = @account.guests.create!(phone_number: "+15550000122", property: @property)
    conversation = guest.conversations.create!(property: @property, status: "escalated")
    alert = conversation.alerts.create!(
      property: @property,
      guest: guest,
      alert_type: "maintenance_issue",
      title: "Problema de aire",
      description: "El aire acondicionado no prende",
      status: "open",
      priority: "high"
    )
    @account.owner_whatsapp_sessions.create!(alert: alert, state: "queued")
    provider = RecordingProvider.new

    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{owner_phone}",
        "To" => "whatsapp:+15550009999",
        "Body" => "Ayla pendientes"
      },
      provider: provider
    ).call

    assert result.fetch(:owner_assistant)
    assert_includes provider.sent_messages.last.fetch(:body), "Pendientes ahora:"
    assert_includes provider.sent_messages.last.fetch(:body), "El aire acondicionado no prende"
  end

  private

  def assert_greeting_routes_to_ai(body:, expected_reply:, expected_language:)
    provider = RecordingProvider.new
    ai_calls = 0
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      ai_calls += 1
      assert_includes guest_message.body, body.split.last
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: expected_language,
        message_body: expected_reply,
        intent_summary: "greeting",
        detected_intents: [{ type: "greeting", status: "answered" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false },
        missing_information: [],
        safety_flags: [],
        confidence: 0.95
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+1555000#{rand(1000..9999)}",
          "To" => "whatsapp:+15550009999",
          "Body" => body
        },
        provider: provider
      ).call
    end

    assert_equal 1, ai_calls
    assert result.fetch(:replied)
    assert_equal expected_reply, result.fetch(:conversation).messages.where(sender: "ai").last.body
    assert_equal expected_reply, provider.sent_messages.last.fetch(:body)
    assert_equal expected_language, result.fetch(:decision).language
    assert_equal 0, result.fetch(:conversation).alerts.count
  end

  def with_ai_decision(decision)
    AI::DecisionService.stub(:call, decision) { yield }
  end

  def ai_checkout_decision
    AI::DecisionResult.from_hash(
      decision: "reply",
      language: "es",
      message_body: "El checkout es a las 11:00.",
      intent_summary: "checkout",
      detected_intents: [{ type: "checkout", status: "answered" }],
      evidence_ids: ["property.check_out_time"],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: false, reason_code: nil, summary_for_host: nil },
      missing_information: [],
      safety_flags: [],
      confidence: 0.95
    )
  end

  def ai_late_checkout_decision
    AI::DecisionResult.from_hash(
      decision: "propose_action",
      language: "en",
      message_body: "Late checkout depends on availability and requires host confirmation. I will share your request with the host.",
      intent_summary: "late checkout",
      detected_intents: [{ type: "guest_request", status: "requires_host_approval" }, { type: "request_late_checkout", status: "requires_host_approval" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: { type: "request_late_checkout", payload: {} },
      escalation: { required: true, reason_code: "booking_change", summary_for_host: "Guest asked for late checkout." },
      missing_information: [],
      safety_flags: [],
      confidence: 0.9,
      owner_task_kind: "request"
    )
  end

  def ai_guest_request_decision(action_type:, intent_type:, message_body: "Perfecto, le aviso al anfitrión sobre tu pedido y te confirmamos en cuanto tengamos respuesta.", intent_status: "requires_host_approval")
    requires_owner = intent_status == "requires_host_approval"
    AI::DecisionResult.from_hash(
      decision: requires_owner ? "propose_action" : "ask_clarifying_question",
      language: "es",
      message_body: message_body,
      intent_summary: "Pedido del huésped",
      detected_intents: [{ type: "guest_request", status: intent_status }, { type: intent_type, status: intent_status }],
      evidence_ids: [],
      required_capabilities: requires_owner ? ["owner_attention"] : [],
      proposed_action: action_type == "none" ? nil : { type: action_type, payload: { title: "Pedido del huésped" } },
      escalation: {
        required: requires_owner,
        reason_code: requires_owner ? "guest_request" : nil,
        summary_for_host: requires_owner ? "El huésped hizo un pedido que requiere revisión del anfitrión." : nil
      },
      missing_information: [],
      safety_flags: [],
      confidence: 0.92,
      owner_task_kind: "request"
    )
  end

  def ai_unknown_decision(language: "es", guest_ack: "No encuentro esa información confirmada para esta propiedad. Ya envié tu consulta al anfitrión para que pueda confirmártela.")
    AI::DecisionResult.from_hash(
      decision: "escalate",
      language: language,
      message_body: guest_ack,
      intent_summary: "unknown",
      detected_intents: [{ type: "unknown_question", status: "escalated" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: true, reason_code: "unknown_question", summary_for_host: "El huésped preguntó algo que Ayla no sabe responder." },
      missing_information: ["visitor_pool_policy"],
      safety_flags: [],
      confidence: 0.9,
      owner_task_kind: "inquiry"
    )
  end

  def ai_operational_alert_decision(language: "es", guest_ack: "Hubo un problema operativo y el equipo fue notificado.")
    AI::DecisionResult.from_hash(
      decision: "escalate",
      language: language,
      message_body: guest_ack,
      intent_summary: "operational failure",
      detected_intents: [{ type: "operational_failure", status: "escalated" }],
      evidence_ids: [],
      required_capabilities: ["owner_attention"],
      proposed_action: nil,
      escalation: { required: true, reason_code: "maintenance", summary_for_host: "Se produjo un problema operativo que requiere atención." },
      missing_information: [],
      safety_flags: ["operational_failure"],
      confidence: 0.9,
      owner_task_kind: nil,
      alert_type: "maintenance_issue",
      alert_title: "Problema operativo"
    )
  end

  def ai_emergency_decision(message_body: "Call 911 first, then contact the host.")
    AI::DecisionResult.from_hash(
      decision: "escalate",
      language: "en",
      message_body: message_body,
      intent_summary: "emergency",
      detected_intents: [{ type: "emergency", status: "escalated" }],
      evidence_ids: ["property.emergency_information"],
      required_capabilities: ["owner_attention"],
      proposed_action: nil,
      escalation: { required: true, category: "emergency", urgency: "urgent", reason_code: "emergency", summary_for_host: "Guest reported an emergency." },
      missing_information: [],
      safety_flags: [],
      confidence: 0.98,
      alert_type: "emergency",
      alert_title: "Emergencia reportada por huésped",
      alert_description: "El huésped reportó una emergencia.",
      suggested_owner_action: "Contactá al huésped de inmediato."
    )
  end
end
