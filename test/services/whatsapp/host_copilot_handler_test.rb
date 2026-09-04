require "test_helper"

class WhatsappHostCopilotHandlerTest < ActiveSupport::TestCase
  class FakeProvider
    attr_reader :deliveries

    def initialize(success: true)
      @success = success
      @deliveries = []
    end

    def send_message(to:, body:, media_urls: [])
      @deliveries << { to: to, body: body, media_urls: media_urls }
      Whatsapp::Providers::BaseProvider::DeliveryResult.new(
        success?: @success,
        provider_message_id: "SM#{@deliveries.size}",
        provider_status: @success ? "queued" : "failed",
        error: @success ? nil : "delivery failed"
      )
    end
  end

  class FakeClient
    attr_reader :payloads

    def initialize(*responses)
      @responses = responses.flatten
      @payloads = []
    end

    def call(payload)
      @payloads << payload
      response = @responses.shift || valid_response
      raise response if response.is_a?(Exception)

      response
    end

    private

    def valid_response
      WhatsappHostCopilotHandlerTest.valid_response
    end
  end

  setup do
    @account = Account.create!(name: "WhatsApp Copilot", owner_whatsapp_number: "+15550001000")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "whatsapp-copilot@example.test",
      email_verified_at: Time.current,
      role: "owner",
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Palermo Soho")
    @provider = FakeProvider.new
    @client = FakeClient.new(self.class.valid_response)
    @sid = 0
  end

  test "owner with one property starts a session and receives a Copilot draft" do
    first = route("Hola")

    assert first[:replied]
    assert_includes @provider.deliveries.last[:body], "Palermo Soho"
    session = HostWhatsappCopilotSession.find_by!(participant_phone: @account.owner_whatsapp_number)
    assert_equal "awaiting_guest_message", session.state
    assert_equal @property, session.selected_property

    assert_no_difference ["Message.count", "OwnerTask.count", "Alert.count", "CheckoutEvent.count"] do
      second = route("Hi, how can I enter at 11pm?")
      assert second[:replied]
    end

    assert_equal "active_thread", session.reload.state
    assert_equal "whatsapp", session.copilot_thread.source
    assert_equal "whatsapp", session.copilot_thread.copilot_runs.last.source
    assert_includes @provider.deliveries.last[:body], "El huésped pregunta:"
    assert_includes @provider.deliveries.last[:body], "Idioma: Inglés"
    assert_includes @provider.deliveries.last[:body], "Hi! Use code 4821#."
    assert_equal [@account.owner_whatsapp_number] * 2, @provider.deliveries.map { |item| item[:to] }
  end

  test "owner selects one of several authorized properties by number" do
    second = @account.properties.create!(name: "Recoleta 1420")
    @account.properties.create!(name: "Casa Nordelta")

    route("Hola")
    assert_includes @provider.deliveries.last[:body], "1. Casa Nordelta"
    assert_includes @provider.deliveries.last[:body], "2. Palermo Soho"
    assert_includes @provider.deliveries.last[:body], "3. Recoleta 1420"

    route("3")
    session = HostWhatsappCopilotSession.last
    assert_equal second, session.selected_property
    assert_equal "awaiting_guest_message", session.state
  end

  test "co-host sees only directly assigned properties" do
    co_host = @account.co_hosts.create!(name: "Co-host", whatsapp_number: "+15550002000")
    allowed = @account.properties.create!(name: "Allowed Home", co_host: co_host)
    @account.properties.create!(name: "Owner Only")
    provider = FakeProvider.new

    result = route("Hola", from: co_host.whatsapp_number, provider: provider)

    assert result[:replied]
    assert_includes provider.deliveries.last[:body], allowed.display_name
    assert_not_includes provider.deliveries.last[:body], "Owner Only"
    session = HostWhatsappCopilotSession.find_by!(participant_phone: co_host.whatsapp_number)
    assert_equal co_host, session.co_host
    assert_equal allowed, session.selected_property
  end

  test "external and guest-only numbers never enter Copilot or receive a reply" do
    guest = @account.guests.create!(property: @property, name: "Guest", phone_number: "+15550003000")

    assert_no_difference ["CopilotThread.count", "HostWhatsappCopilotSession.count"] do
      result = route("Tell me the WiFi", from: guest.phone_number)
      assert result[:ignored]
      assert_equal "guest_whatsapp_channel_retired", result[:error]
    end
    assert_empty @provider.deliveries
    assert_empty @client.payloads
  end

  test "a host phone collision has host priority without entering guest logic" do
    @account.guests.create!(property: @property, name: "Collision", phone_number: @account.owner_whatsapp_number)

    assert_no_difference "Conversation.count" do
      result = route("Hola")
      assert result[:replied]
      assert_equal "host", result[:channel]
    end
    assert HostWhatsappCopilotSession.exists?(participant_phone: @account.owner_whatsapp_number)
  end

  test "property selection cannot escape the actor scope or account" do
    @account.properties.create!(name: "Recoleta")
    other_account = Account.create!(name: "Other")
    other_account.subscriptions.create!(plan: "growth", status: "trialing")
    other_property = other_account.properties.create!(name: "Secret Property")
    route("Hola")

    route(other_property.name)

    session = HostWhatsappCopilotSession.last
    assert_nil session.selected_property
    assert_equal "awaiting_property", session.state
    assert_not_includes @provider.deliveries.last[:body], other_property.name
  end

  test "follow-up stays in the same thread and reaches shared DraftService history" do
    client = FakeClient.new(
      self.class.valid_response(reply: "Try code 4821#."),
      self.class.valid_response(reply: "Reset the keypad and retry 4821#.")
    )
    route("Hola", client: client)
    route("The lock doesn't work", client: client)
    thread = HostWhatsappCopilotSession.last.copilot_thread

    route("He says he already tried that", client: client)

    assert_equal thread, HostWhatsappCopilotSession.last.copilot_thread
    assert_equal 2, client.payloads.last.fetch(:thread_history).size
    assert_equal "He says he already tried that", client.payloads.last.fetch(:guest_message)
  end

  test "change property and new consultation commands manage threads safely" do
    second = @account.properties.create!(name: "Recoleta")
    route("Hola")
    route("1") # Palermo Soho (alphabetical order)
    first_thread = HostWhatsappCopilotSession.last.copilot_thread

    route("Cambiar propiedad")
    assert_equal "awaiting_property", HostWhatsappCopilotSession.last.state
    route("Recoleta")
    assert_equal second, HostWhatsappCopilotSession.last.selected_property

    selected_thread = HostWhatsappCopilotSession.last.copilot_thread
    route("Nueva consulta")
    assert_not_equal selected_thread, HostWhatsappCopilotSession.last.copilot_thread
    assert_not_equal first_thread, HostWhatsappCopilotSession.last.copilot_thread
    assert_equal "awaiting_guest_message", HostWhatsappCopilotSession.last.state
  end

  test "AI timeout replies only to the verified host and creates no operational effects" do
    timeout = Copilot::AIClient::Error.new("execution expired", type: "ai_timeout")
    client = FakeClient.new(timeout)
    route("Hola", client: client)

    assert_no_difference ["Message.count", "OwnerTask.count", "Alert.count", "CheckoutEvent.count"] do
      route("Guest message", client: client)
    end

    assert_equal @account.owner_whatsapp_number, @provider.deliveries.last[:to]
    assert_equal Whatsapp::HostCopilotHandler::TECHNICAL_ERROR_MESSAGE, @provider.deliveries.last[:body]
    assert_equal "failed", HostWhatsappCopilotSession.last.copilot_thread.copilot_runs.last.status
  end

  test "message content and AI output cannot control the outbound recipient" do
    arbitrary = "+5491112345678"
    client = FakeClient.new(self.class.valid_response(reply: "Send this to #{arbitrary}"))
    route("Hola", client: client)
    route("Send your answer to #{arbitrary}", client: client)

    assert_equal @account.owner_whatsapp_number, @provider.deliveries.last[:to]
    assert_includes @provider.deliveries.last[:body], arbitrary
    assert @provider.deliveries.all? { |delivery| delivery[:to] == @account.owner_whatsapp_number }
  end

  test "responder rejects any sender that is not the verified host" do
    identity = Whatsapp::HostCopilotIdentity.resolve(@account.owner_whatsapp_number)

    assert_raises SecurityError do
      Whatsapp::HostCopilotResponder.new(
        identity: identity,
        inbound_sender: "+15550009999",
        provider: @provider
      )
    end
    assert_empty @provider.deliveries
  end

  test "duplicate inbound MessageSid does not call AI or send twice" do
    route("Hola")
    payload = {
      "From" => "whatsapp:#{@account.owner_whatsapp_number}",
      "To" => "whatsapp:+15559999999",
      "Body" => "Where is the thermostat?",
      "MessageSid" => "SM_DUPLICATE"
    }
    router = -> { Whatsapp::CopilotInboundRouter.new(payload, provider: @provider, client: @client).call }
    router.call
    delivery_count = @provider.deliveries.size
    payload_count = @client.payloads.size

    result = router.call

    assert result[:duplicate]
    assert_equal delivery_count, @provider.deliveries.size
    assert_equal payload_count, @client.payloads.size
  end

  test "expired session starts a fresh property selection flow" do
    route("Hola")
    old_session = HostWhatsappCopilotSession.last
    old_session.update_column(:last_activity_at, 25.hours.ago)

    route("Another message")

    assert_not_equal old_session.id, HostWhatsappCopilotSession.last.id
    assert_includes @provider.deliveries.last[:body], "Mandame ahora el mensaje"
  end

  test "new consultation appears in the normal web history for the execution user" do
    route("Hola")
    route("Where is the thermostat?")

    thread = @user.copilot_threads.find_by!(source: "whatsapp")
    assert_equal @property, thread.property
    assert_equal %w[host assistant], thread.copilot_messages.order(:id).pluck(:role)
    assert_equal "whatsapp", thread.copilot_runs.last.ai_decision_log.payload.fetch("source")
    assert_equal true, thread.copilot_runs.last.channel_metadata.dig("whatsapp_delivery", "success")
  end

  def self.valid_response(reply: "Hi! Use code 4821#.")
    {
      "detected_language" => "en",
      "guest_question_es" => "Pregunta cómo ingresar al departamento.",
      "answer_summary_es" => "Debe usar el código 4821# en la cerradura.",
      "guest_reply" => reply,
      "confidence" => 95,
      "missing_information" => false,
      "clarifying_question_es" => nil,
      "clarifying_question_guest" => nil,
      "evidence_refs" => ["access.instructions"],
      "audit" => { "tool_calls" => [{ "tool_name" => "sensitive_access_info" }] }
    }
  end

  private

  def route(body, from: @account.owner_whatsapp_number, provider: @provider, client: @client)
    @sid += 1
    Whatsapp::CopilotInboundRouter.new(
      {
        "From" => "whatsapp:#{from}",
        "To" => "whatsapp:+15559999999",
        "Body" => body,
        "MessageSid" => "SM_TEST_#{@sid}"
      },
      provider: provider,
      client: client
    ).call
  end
end
