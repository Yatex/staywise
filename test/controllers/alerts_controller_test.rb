require "test_helper"

class AlertsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Alert Test")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "alert-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Alert Apartment")
    @guest = @account.guests.create!(phone_number: "+15550001000", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    @guest_message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Dónde hay toallas extra?")
    @alert = @property.alerts.create!(
      guest: @guest,
      conversation: @conversation,
      original_message: @guest_message,
      alert_type: "unknown_question",
      title: "La pregunta necesita respuesta del anfitrión",
      description: '{"internal_note":"payload que no debe ver el owner"}',
      status: "open",
      priority: "medium"
    )

    sign_in_as(@user)
  end

  test "show presents the original guest message instead of the internal description" do
    get alert_path(@alert)

    assert_response :success
    assert_select "p", text: "Mensaje del huésped"
    assert_select "p", text: @guest_message.body
    assert_select "a[href='#{conversation_path(@conversation)}']", text: "Responder al huésped"
    assert_select "a", text: "Abrir conversación", count: 0
    assert_no_match(/internal_note|payload que no debe ver/, response.body)
  end

  test "answering an unknown question creates active faq and resolves alert" do
    assert_difference -> { @property.faqs.count }, 1 do
      post answer_question_alert_path(@alert), params: {
        faq: {
          question: "¿Dónde hay toallas extra?",
          answer: "Las toallas extra están en el placard del pasillo."
        }
      }
    end

    assert_redirected_to property_path(@property, anchor: "new-questions")
    faq = @property.faqs.order(:created_at).last
    assert_equal "¿Dónde hay toallas extra?", faq.question
    assert_equal "Las toallas extra están en el placard del pasillo.", faq.answer
    assert_equal "custom_notes", faq.category
    assert faq.active?
    assert_equal "resolved", @alert.reload.status
  end

  test "index lets owner mark an open alert as done" do
    get alerts_path

    assert_response :success
    assert_select "form[action='#{alert_path(@alert)}'] button", text: I18n.t("ui.alerts.mark_done")

    patch alert_path(@alert), params: { alert: { status: "resolved" } }

    assert_redirected_to alerts_path
    assert_equal "resolved", @alert.reload.status
    assert_not_nil @alert.resolved_at
  end

  test "index never exposes technical JSON and explains the alert in plain language" do
    @alert.update!(
      original_message: nil,
      alert_type: "late_checkout_request",
      title: "Solicitud de late checkout",
      description: {
        requested_time: "6:00 PM",
        guest_message: "hasta las 6pm",
        note: "El huésped quiere extender su salida y necesita aprobación.",
        evidence: ["property.check_out_time", "policy.late_checkout"]
      }.to_json
    )

    get alerts_path

    assert_response :success
    assert_includes response.body, "Pedido para salir más tarde"
    assert_includes response.body, "El huésped escribió: “hasta las 6pm”"
    assert_includes response.body, "Horario solicitado: 6:00 PM."
    assert_includes response.body, "El huésped quiere extender su salida y necesita aprobación."
    assert_no_match(/requested_time|guest_message|evidence|property\.check_out_time|policy\.late_checkout|\{&quot;/, response.body)
  end

  test "index hides technical-only JSON when no useful owner information exists" do
    @alert.update!(original_message: nil, description: { evidence: ["property.address"] }.to_json)

    get alerts_path

    assert_response :success
    assert_no_match(/evidence|property\.address|\{&quot;/, response.body)
  end

  test "alerts are paginated at twenty five" do
    26.times do |index|
      @property.alerts.create!(
        guest: @guest,
        conversation: @conversation,
        alert_type: "unknown_question",
        title: "Alerta paginada #{index}",
        description: "Descripción visible #{index}",
        status: "open",
        priority: "medium"
      )
    end

    get alerts_path
    assert_response :success
    assert_equal 25, response.body.scan(%r{href="/alerts/\d+"}).size
    assert_select "a", text: "Siguiente", count: 1

    get alerts_path(page: 2)
    assert_response :success
    assert_equal 2, response.body.scan(%r{href="/alerts/\d+"}).size
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
