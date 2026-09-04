require "application_system_test_case"

class CopilotChatTest < ApplicationSystemTestCase
  setup do
    @account = Account.create!(name: "Copilot UI")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Host",
      email: "copilot-system@example.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    property = @account.properties.create!(name: "Apartment Palermo")
    @thread = @user.copilot_threads.create!(account: @account, property: property, title: "Llegada tarde")
    @thread.copilot_messages.create!(account: @account, property: property, user: @user, role: "host", content: "Bonjour, nous arriverons vers 23h.")
    @thread.copilot_messages.create!(
      account: @account,
      property: property,
      user: @user,
      role: "assistant",
      content: "Bonjour ! Utilisez le code 4821#.",
      structured_content: {
        "detected_language" => "fr",
        "guest_question_es" => "El huésped llegará a las 23:00 y pregunta cómo entrar.",
        "answer_summary_es" => "Debe usar el código de la cerradura.",
        "guest_reply" => "Bonjour ! Utilisez le code 4821#.",
        "missing_information" => false
      }
    )
  end

  test "host reviews and copies a draft without an automatic send action" do
    visit login_path
    page.all("input[type='email']").first.set(@user.email)
    fill_in "Password", with: "password123"
    click_button "Ingresar"
    assert_current_path dashboard_path
    visit copilot_thread_path(@thread)

    assert_text(/mensaje original del huésped/i)
    assert_text(/entendí que pregunta/i)
    assert_text "Francés"
    assert_text(/mensaje para enviar/i)
    assert_button "Copiar respuesta"
    assert_no_button "Enviar al huésped"
    assert_field placeholder: "Escribí un seguimiento, por ejemplo: Me respondió que el código no funciona"
  end
end
