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

  test "shows pending inquiries separately from alerts" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Puedo hacer más tarde el checkout?")
    @conversation.owner_tasks.create!(
      account: @account, property: @property, guest: @guest, message: message,
      kind: "inquiry", guest_phone: @guest.phone_number, property_name: @property.display_name,
      category: "other", title: "Consulta pendiente", description: message.body,
      status: "open", priority: "normal", source_channel: "whatsapp"
    )

    get dashboard_path

    assert_response :success
    assert_includes @response.body, "Puedo hacer más tarde el checkout?"
    assert_includes @response.body, "Consultas pendientes"
    assert_includes @response.body, "New Charming Design Center"
    assert_not_includes @response.body, "Alertas importantes"
  end

  test "shows whatsapp configuration warning with settings link" do
    get dashboard_path

    assert_response :success
    assert_select "[data-testid='owner-whatsapp-warning']", 1 do
      assert_select "a[href='#{settings_path}']", text: "Configurar WhatsApp"
    end
    assert_includes response.body, "No estás recibiendo notificaciones por WhatsApp"
  end

  test "hides whatsapp warning when owner notifications are configured" do
    @account.update!(owner_whatsapp_number: "+59899123456", owner_whatsapp_escalations_enabled: true)

    get dashboard_path

    assert_response :success
    assert_select "[data-testid='owner-whatsapp-warning']", 0
  end

  test "does not show recent chats on dashboard" do
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Hola")

    get dashboard_path

    assert_response :success
    assert_not_includes @response.body, "Chats recientes"
    assert_not_includes @response.body, "15550002000"
    assert_not_includes @response.body, "Huésped de WhatsApp"
  end

  test "shows pending guest requests" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "quiero un vino")
    @conversation.guest_requests.create!(
      account: @account,
      property: @property,
      guest: @guest,
      message: message,
      guest_phone: @guest.phone_number,
      property_name: @property.display_name,
      property_address: @property.address,
      category: "food_or_drink",
      title: "Pedido de comida o bebida",
      description: "quiero un vino",
      status: "open",
      priority: "normal",
      source_channel: "whatsapp"
    )

    get dashboard_path

    assert_response :success
    assert_includes @response.body, "Pedidos pendientes"
    assert_includes @response.body, "Pedido de comida o bebida"
    assert_includes @response.body, "quiero un vino"
  end

  test "shows inquiry created by ai escalation from whatsapp flow without alert" do
    decision = AI::DecisionResult.from_hash(
      decision: "escalate",
      language: "es",
      message_body: "No tengo esa información confirmada todavía. Voy a pedir que el anfitrión la revise.",
      intent_summary: "unknown",
      detected_intents: [{ type: "unknown_question", status: "escalated" }],
      evidence_ids: [],
      required_capabilities: [],
      proposed_action: nil,
      escalation: { required: true, reason_code: "unknown_question", summary_for_host: "El huésped preguntó si puede hacer más tarde el checkout." },
      missing_information: ["late_checkout_policy"],
      safety_flags: [],
      confidence: 0.9,
      owner_task_kind: "inquiry"
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

    inquiry = result.fetch(:guest_request)
    assert_nil result.fetch(:alert)
    assert_equal "inquiry", inquiry.kind
    assert_equal @property, inquiry.property

    get dashboard_path

    assert_response :success
    assert_includes @response.body, "Puedo hacer más tarde el checkout?"
    assert_includes @response.body, "Consultas pendientes"
    assert_includes @response.body, "New Charming Design Center"
    assert_not_includes @response.body, "Alertas importantes"
  end

  test "shows operational alerts in a compact collapsed section above owner tasks" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Hay humo en la cocina")
    @property.alerts.create!(
      guest: @guest, conversation: @conversation, original_message: message,
      alert_type: "emergency", title: "Posible emergencia", description: message.body,
      status: "open", priority: "urgent"
    )

    get dashboard_path

    assert_response :success
    assert_select "details:not([open])" do
      assert_select "summary", text: /Alertas importantes/
      assert_select "a[href='#{alert_path(@property.alerts.last)}']", text: /Posible emergencia/
    end
    assert_operator response.body.index("Alertas importantes"), :<, response.body.index("Pedidos pendientes")
    assert_operator response.body.index("Pedidos pendientes"), :<, response.body.index("Consultas pendientes")
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
