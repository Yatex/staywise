require "test_helper"

class CopilotThreadsControllerTest < ActionDispatch::IntegrationTest
  FakeClient = Struct.new(:response) do
    def call(_payload)
      response
    end
  end

  setup do
    @account = Account.create!(name: "Copilot Web")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Host",
      email: "copilot-web@example.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Web Apartment")
    @other_account = Account.create!(name: "Other Copilot")
    @other_account.subscriptions.create!(plan: "growth", status: "trialing")
    @other_user = @other_account.users.create!(
      name: "Other",
      email: "other-copilot@example.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @other_property = @other_account.properties.create!(name: "Secret Apartment")
    sign_in_as(@user)
  end

  test "authentication is required" do
    delete logout_path
    get copilot_threads_path
    assert_redirected_to login_path
  end

  test "new consultation presents the host copilot flow and focused navigation" do
    get new_copilot_thread_path

    assert_response :success
    assert_includes response.body, "¿Sobre qué propiedad querés consultar?"
    assert_includes response.body, "Pegá acá el mensaje que recibiste del huésped"
    assert_includes response.body, "Nueva consulta"
    assert_includes response.body, "Historial"
    assert_includes response.body, "Propiedades"
    assert_includes response.body, "Configuración"
    assert_includes response.body, "Operación anterior"
  end

  test "index only displays the authenticated user's threads" do
    own = @user.copilot_threads.create!(account: @account, property: @property, title: "Own question")
    @other_user.copilot_threads.create!(account: @other_account, property: @other_property, title: "Secret question")

    get copilot_threads_path

    assert_response :success
    assert_includes response.body, own.title
    assert_not_includes response.body, "Secret question"
  end

  test "show rejects a thread from another account" do
    thread = @other_user.copilot_threads.create!(account: @other_account, property: @other_property)

    get copilot_thread_path(thread)

    assert_response :not_found
  end

  test "create rejects a property from another account before calling AI" do
    assert_no_difference -> { CopilotThread.count } do
      post copilot_threads_path, params: {
        property_id: @other_property.id,
        guest_message: "What is the WiFi?"
      }
    end

    assert_redirected_to new_copilot_thread_path
  end

  test "authenticated host creates a thread and receives a reviewable draft without guest delivery" do
    response_payload = {
      "detected_language" => "en",
      "guest_question_es" => "Pregunta cómo encender la calefacción.",
      "answer_summary_es" => "Debe usar el termostato.",
      "guest_reply" => "Use the wall thermostat.",
      "confidence" => 90,
      "missing_information" => false,
      "clarifying_question_es" => nil,
      "clarifying_question_guest" => nil,
      "evidence_refs" => ["guide.1"],
      "audit" => { "tool_calls" => [{ "tool_name" => "property_brain" }] }
    }

    assert_no_difference -> { Message.count } do
      Copilot::AIClient.stub(:new, -> { FakeClient.new(response_payload) }) do
        post copilot_threads_path, params: {
          property_id: @property.id,
          guest_message: "How do I turn on the heating?",
          host_context: "They checked in today."
        }
      end
    end

    thread = @user.copilot_threads.last
    assert_redirected_to copilot_thread_path(thread)
    assert_equal %w[host assistant], thread.copilot_messages.order(:created_at).pluck(:role)
    get copilot_thread_path(thread)
    assert_response :success
    assert_includes response.body, "Vos pegaste"
    assert_includes response.body, "Mensaje original del huésped"
    assert_includes response.body, "Entendí que pregunta"
    assert_includes response.body, "Respuesta"
    assert_includes response.body, "Idioma"
    assert_includes response.body, "Inglés"
    assert_includes response.body, "Mensaje para enviar"
    assert_includes response.body, "Copiar respuesta"
    assert_includes response.body, "Use the wall thermostat."
    assert_not_includes response.body, "Enviar al huésped"
  end

  test "missing information is explicit and offers a copyable guest question" do
    thread = @user.copilot_threads.create!(account: @account, property: @property)
    thread.copilot_messages.create!(account: @account, property: @property, user: @user, role: "host", content: "It does not work")
    thread.copilot_messages.create!(
      account: @account,
      property: @property,
      user: @user,
      role: "assistant",
      content: "Which device is not working?",
      structured_content: response_payload.merge(
        "guest_reply" => nil,
        "missing_information" => true,
        "clarifying_question_es" => "Necesito saber qué equipo no funciona.",
        "clarifying_question_guest" => "Which device is not working?"
      )
    )

    get copilot_thread_path(thread)

    assert_response :success
    assert_includes response.body, "No tengo suficiente información para responder esto con seguridad."
    assert_includes response.body, "Necesito saber qué equipo no funciona."
    assert_includes response.body, "Copiar pregunta"
  end

  private

  def response_payload
    {
      "detected_language" => "en",
      "guest_question_es" => "Pregunta cómo encender la calefacción.",
      "answer_summary_es" => "Debe usar el termostato.",
      "guest_reply" => "Use the wall thermostat.",
      "confidence" => 90,
      "missing_information" => false,
      "clarifying_question_es" => nil,
      "clarifying_question_guest" => nil,
      "evidence_refs" => ["guide.1"]
    }
  end

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
