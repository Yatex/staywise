require "test_helper"

class CopilotDraftServiceTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:response, :received_payload) do
    def call(payload)
      self.received_payload = payload
      response
    end
  end

  setup do
    @account = Account.create!(name: "Copilot Service")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Host",
      email: "copilot-service@example.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Palermo Apartment")
    @thread = @user.copilot_threads.create!(account: @account, property: @property)
    @original_app_host = ENV["APP_HOST"]
    ENV["APP_HOST"] = "https://ayla.test"
  end

  teardown do
    ENV["APP_HOST"] = @original_app_host
  end

  test "persists Spanish explanation and reply in each original guest language" do
    {
      "en" => "Use the thermostat on the wall.",
      "pt" => "Use o termostato na parede.",
      "es" => "Usá el termostato de la pared."
    }.each do |language, reply|
      thread = @user.copilot_threads.create!(account: @account, property: @property)
      result = Copilot::DraftService.call(
        thread: thread,
        content: "Guest question in #{language}",
        client: FakeClient.new(valid_response(language: language, reply: reply))
      )

      assert result.success?
      assert_equal language, result.run.detected_language
      assert_equal "Pregunta cómo encender la calefacción.", result.run.guest_question_es
      assert_equal reply, result.run.guest_reply
    end
  end

  test "thread continuation includes prior turns and optional host context" do
    first_client = FakeClient.new(valid_response(language: "en", reply: "Press HEAT."))
    Copilot::DraftService.call(thread: @thread, content: "How do I turn on heating?", client: first_client)
    second_client = FakeClient.new(valid_response(language: "en", reply: "Try resetting it."))

    result = Copilot::DraftService.call(
      thread: @thread,
      content: "The guest says that did not work.",
      host_context: "They checked in today.",
      client: second_client
    )

    assert result.success?
    assert_equal 2, second_client.received_payload.fetch(:thread_history).size
    assert_equal "They checked in today.", second_client.received_payload.fetch(:host_context)
    assert_equal "/internal/ai/copilot_tools", second_client.received_payload.dig(:tool_endpoint, :path_prefix)
  end

  test "missing information persists clarification without fabricating a reply" do
    response = valid_response(language: "en", reply: nil).merge(
      "missing_information" => true,
      "clarifying_question_es" => "¿Qué equipo intenta utilizar?",
      "clarifying_question_guest" => "Which device are you trying to use?",
      "confidence" => 25
    )
    result = Copilot::DraftService.call(thread: @thread, content: "It does not work", client: FakeClient.new(response))

    assert result.success?
    assert result.run.missing_information?
    assert_nil result.run.guest_reply
    assert_equal "¿Qué equipo intenta utilizar?", result.run.clarifying_question_es
    assert_equal "Which device are you trying to use?", result.run.clarifying_question_guest
  end

  test "malformed AI response is recorded as failed and creates no assistant message" do
    client = FakeClient.new({ "detected_language" => "en" })

    result = Copilot::DraftService.call(thread: @thread, content: "Question", client: client)

    assert_not result.success?
    assert_equal "malformed_response", result.run.error_type
    assert_equal ["host"], @thread.copilot_messages.pluck(:role)
    assert_equal "copilot_failed", AIDecisionLog.last.route
  end

  test "AI timeout is recorded and never sends an outbound guest message" do
    timeout_client = Object.new
    timeout_client.define_singleton_method(:call) do |_payload|
      raise Copilot::AIClient::Error.new("execution expired", type: "ai_timeout")
    end

    assert_no_difference -> { Message.count } do
      result = Copilot::DraftService.call(thread: @thread, content: "Question", client: timeout_client)
      assert_not result.success?
      assert_equal "ai_timeout", result.run.error_type
    end
    assert_equal 0, OwnerTask.count
    assert_equal 0, Alert.count
  end

  test "a successful Copilot interaction cannot produce guest outbound or operational effects" do
    provider_factory = Whatsapp::ProviderFactory
    provider_factory.stub(:build, -> { flunk "Copilot must not construct a WhatsApp provider" }) do
      assert_no_difference ["Message.count", "OwnerTask.count", "Alert.count", "CheckoutEvent.count"] do
        result = Copilot::DraftService.call(
          thread: @thread,
          content: "How do I enter?",
          client: FakeClient.new(valid_response(language: "en", reply: "Use code 4821#."))
        )

        assert result.success?
        assert_equal "Use code 4821#.", result.assistant_message.content
      end
    end
  end

  test "tool audit and evidence references are persisted in AI Trace" do
    response = valid_response(language: "en", reply: "Use code 4821#.").merge(
      "evidence_refs" => ["property.door_code"],
      "audit" => { "tool_calls" => [{ "tool_name" => "sensitive_access_info" }] }
    )
    result = Copilot::DraftService.call(thread: @thread, content: "How do I enter?", client: FakeClient.new(response))

    assert result.success?
    trace = result.run.ai_decision_log
    assert_equal ["property.door_code"], trace.evidence_ids
    assert_equal "sensitive_access_info", trace.tool_calls.first.fetch("tool_name")
    assert_equal "/copilot", trace.ai_request_payload.fetch("endpoint")
    assert_equal @property.id, trace.ai_request_payload.dig("property", "id")
    assert_equal @user.id, trace.ai_request_payload.dig("user", "id")
    assert_equal "How do I enter?", trace.ai_request_payload.fetch("guest_message")
  end

  private

  def valid_response(language:, reply:)
    {
      "detected_language" => language,
      "guest_question_es" => "Pregunta cómo encender la calefacción.",
      "answer_summary_es" => "Se propone usar el termostato de la pared.",
      "guest_reply" => reply,
      "confidence" => 92,
      "missing_information" => false,
      "clarifying_question_es" => nil,
      "clarifying_question_guest" => nil,
      "evidence_refs" => ["guide.1"],
      "audit" => { "tool_calls" => [{ "tool_name" => "property_brain" }] }
    }
  end
end
