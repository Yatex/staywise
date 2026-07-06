require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Dashboard Test")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "dashboard-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "New Charming Design Center")
    @guest = @account.guests.create!(phone_number: "+15550002000", property: @property)
    @conversation = @guest.conversations.create!(property: @property)

    sign_in_as(@user)
  end

  test "shows open unknown question alerts" do
    @property.alerts.create!(
      guest: @guest,
      conversation: @conversation,
      alert_type: "unknown_question",
      title: "Pregunta sin configurar",
      description: "Puedo hacer más tarde el checkout?",
      status: "open",
      priority: "medium"
    )

    get dashboard_path

    assert_response :success
    assert_includes @response.body, "Pregunta sin configurar"
    assert_includes @response.body, "New Charming Design Center"
    assert_not_includes @response.body, "No hay alertas abiertas"
  end

  test "shows alert created by ai escalation from whatsapp flow" do
    decision = AI::DecisionResult.from_hash(
      decision: "escalate",
      language: "es",
      message_body: "No tengo esa información confirmada todavía. Voy a pedir que el anfitrión la revise.",
      intent_summary: "unknown",
      detected_intents: [{ type: "late_checkout", status: "escalated" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: true, reason_code: "unknown_question", summary_for_host: "El huésped preguntó si puede hacer más tarde el checkout." },
      missing_information: ["late_checkout_policy"],
      safety_flags: [],
      confidence: 0.9
    )
    result = nil

    AI::DecisionService.stub(:call, decision) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550009988",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} Puedo hacer más tarde el checkout?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    alert = result.fetch(:alert)

    assert_equal "unknown_question", alert.alert_type
    assert_equal "open", alert.status
    assert_equal @property, alert.property
    assert_equal result.fetch(:conversation), alert.conversation

    get dashboard_path

    assert_response :success
    assert_includes @response.body, "Pregunta sin configurar"
    assert_includes @response.body, "New Charming Design Center"
    assert_not_includes @response.body, "No hay alertas abiertas"
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
