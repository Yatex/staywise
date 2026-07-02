require "test_helper"

class WhatsappIncomingMessageHandlerTest < ActiveSupport::TestCase
  class FailingProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:)
      false
    end
  end

  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :sent_messages

    def initialize
      @sent_messages = []
    end

    def send_message(to:, body:)
      @sent_messages << { to: to, body: body }
      super
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

  test "creates guest conversation messages and alert from incoming whatsapp payload" do
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
    assert_equal "escalated", conversation.reload.status
    assert_equal "+15550000002", conversation.guest.phone_number
    assert_equal 2, conversation.messages.count
    assert_equal "late_checkout_request", conversation.alerts.first.alert_type
  end

  test "does not store an ai message when whatsapp delivery fails" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000003",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} Can I get late checkout?"
      },
      provider: FailingProvider.new
    ).call

    conversation = result.fetch(:conversation)

    assert_not result.fetch(:replied)
    assert_equal 1, conversation.messages.count
    assert_equal ["guest"], conversation.messages.pluck(:sender)
  end

  test "english emergency phrase creates urgent alert without ai service" do
    previous_ai_service_url = ENV["AI_SERVICE_URL"]
    ENV["AI_SERVICE_URL"] = "http://127.0.0.1:1"
    @property.update!(emergency_information: "Call 911 first, then contact the host.")

    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000004",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} There is smoke in the apartment, emergency"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    alert = result.fetch(:conversation).alerts.first

    assert result.fetch(:replied)
    assert_equal "emergency", alert.alert_type
    assert_equal "urgent", alert.priority
    assert_includes result.fetch(:conversation).messages.where(sender: "ai").last.body, "911"
  ensure
    ENV["AI_SERVICE_URL"] = previous_ai_service_url
  end

  test "spanish emergency phrase creates urgent alert" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000005",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} Hay una fuga de gas"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    alert = result.fetch(:conversation).alerts.first

    assert_equal "emergency", alert.alert_type
    assert_equal "urgent", alert.priority
  end

  test "default qr intro gets ai greeting without creating alert" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000008",
        "To" => "whatsapp:+15550009999",
        "Body" => "Hola, tengo una consulta sobre #{@property.display_name}. #{@property.whatsapp_reference}"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    conversation = result.fetch(:conversation)

    assert result.fetch(:replied)
    assert_nil result.fetch(:alert)
    assert_equal 0, conversation.alerts.count
    assert_equal "ask_clarifying_question", result.fetch(:decision).outcome
    assert_includes conversation.messages.where(sender: "ai").last.body, "¿En qué puedo ayudarte?"
    assert_includes conversation.messages.where(sender: "ai").last.body, "este chat está compartido con el dueño de la propiedad"
  end

  test "first concrete ai answer also discloses that chat is shared with owner" do
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
    assert_includes body, "este chat está compartido con el dueño de la propiedad"
  end

  test "owner disclosure is not repeated after first ai response" do
    @property.update!(checkout_time: "11:00")
    phone_number = "whatsapp:+15550000010"

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => phone_number,
        "To" => "whatsapp:+15550009999",
        "Body" => "Hola, tengo una consulta sobre #{@property.display_name}. #{@property.whatsapp_reference}"
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

    assert result.fetch(:replied)
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

    assert result.fetch(:replied)
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
    assert_equal "late_checkout_request", result.fetch(:conversation).alerts.first.alert_type
  end

  test "owner can answer escalated alert by whatsapp and response is saved for future property questions" do
    @account.update!(owner_whatsapp_number: "+15559990000", owner_whatsapp_escalations_enabled: true)
    @property.update!(checkout_time: "11:00")

    guest_result = with_ai_decision(ai_unknown_decision) do
      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550000012",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Puedo invitar gente a la pileta?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    alert = guest_result.fetch(:alert)
    session = @account.owner_whatsapp_sessions.find_by!(alert: alert)
    assert_equal "awaiting_ack", session.state

    detail_result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990000",
        "To" => "whatsapp:+15550009999",
        "Body" => "Ver detalle"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert detail_result.fetch(:owner_message)
    assert_equal "awaiting_answer", session.reload.state

    answer_result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990000",
        "To" => "whatsapp:+15550009999",
        "Body" => "No se pueden invitar personas a la pileta."
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert answer_result.fetch(:owner_message)
    assert_equal "resolved", alert.reload.status
    assert_equal "resolved", session.reload.state
    assert_includes guest_result.fetch(:conversation).messages.where(sender: "owner").last.body, "No se pueden invitar"
    assert_equal "No se pueden invitar personas a la pileta.", @property.faqs.last.answer
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
      guest_result = with_ai_decision(ai_unknown_decision(language: "ru", guest_ack: "Спасибо за сообщение. Я уточню это у хозяина и скоро отвечу.")) do
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

      assert_equal "¿Puedo invitar gente a la pileta?", alert.description

      Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15559990003",
          "To" => "whatsapp:+15550009999",
          "Body" => "Ver detalle"
        },
        provider: provider
      ).call

      assert_includes provider.sent_messages.last.fetch(:body), "¿Puedo invitar gente a la pileta?"

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
      assert_equal "¿Puedo invitar gente a la pileta?", @property.faqs.last.question
      assert_equal "No se pueden invitar personas a la pileta.", @property.faqs.last.answer
      assert_equal "resolved", session.reload.state
    end
  end

  test "owner whatsapp handles one active alert at a time and can hold the current one" do
    @account.update!(owner_whatsapp_number: "+15559990001", owner_whatsapp_escalations_enabled: true)
    property_two = @account.properties.create!(name: "Second Apartment")
    guest_one = @account.guests.create!(phone_number: "+15550000101", property: @property)
    guest_two = @account.guests.create!(phone_number: "+15550000102", property: property_two)
    conversation_one = guest_one.conversations.create!(property: @property)
    conversation_two = guest_two.conversations.create!(property: property_two)
    alert_one = conversation_one.alerts.create!(property: @property, guest: guest_one, alert_type: "unknown_question", title: "Question one", description: "Question one")
    alert_two = conversation_two.alerts.create!(property: property_two, guest: guest_two, alert_type: "unknown_question", title: "Question two", description: "Question two")

    first = Whatsapp::OwnerEscalationNotifier.call(alert: alert_one, provider: Whatsapp::Providers::NullProvider.new)
    second = Whatsapp::OwnerEscalationNotifier.call(alert: alert_two, provider: Whatsapp::Providers::NullProvider.new)

    assert first.sent?
    assert_not second.sent?
    assert_equal "awaiting_ack", first.session.reload.state
    assert_equal "queued", second.session.reload.state

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15559990001",
        "To" => "whatsapp:+15550009999",
        "Body" => "Pausar"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_equal "on_hold", first.session.reload.state
    assert_equal "awaiting_ack", second.session.reload.state
  end

  test "owner whatsapp queues alerts across accounts when the same owner phone is reused" do
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

    first = Whatsapp::OwnerEscalationNotifier.call(alert: alert_one, provider: Whatsapp::Providers::NullProvider.new)
    second = Whatsapp::OwnerEscalationNotifier.call(alert: alert_two, provider: Whatsapp::Providers::NullProvider.new)

    assert first.sent?
    assert_not second.sent?
    assert_equal "queued", second.session.reload.state

    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{owner_phone}",
        "To" => "whatsapp:+15550009999",
        "Body" => "HOLD"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert_equal "on_hold", first.session.reload.state
    assert_equal "awaiting_ack", second.session.reload.state
  end

  private

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
      message_body: "Late checkout depends on availability and requires host confirmation. I have sent your request.",
      intent_summary: "late checkout",
      detected_intents: [{ type: "late_checkout", status: "requires_host_approval" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: { type: "request_late_checkout", payload: {} },
      escalation: { required: true, reason_code: "booking_change", summary_for_host: "Guest asked for late checkout." },
      missing_information: [],
      safety_flags: [],
      confidence: 0.9
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
      confidence: 0.9
    )
  end
end
