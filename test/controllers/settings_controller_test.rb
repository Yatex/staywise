require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Settings Stays")
    @account.subscriptions.create!(plan: "starter", status: "trialing")
    @user = @account.users.create!(
      name: "Settings Owner",
      email: "settings-owner@staywise.test",
      role: "owner",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  test "settings only exposes the general ai toggle" do
    sign_in_as(@user)

    get settings_path

    assert_response :success
    assert_includes response.body, "Ayla AI activa para esta cuenta"
    assert_no_match(/Asistente IA|Instrucciones de IA|Tono de voz|late_checkout_policy/, response.body)
  end

  test "owner can turn ai off for the account" do
    sign_in_as(@user)

    patch settings_path, params: {
      account: {
        name: @account.name,
        ai_active: "0"
      }
    }

    assert_redirected_to settings_path
    assert_not @account.reload.ai_active?
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
