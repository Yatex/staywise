require "test_helper"

class BillingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Billing Controller Stays")
    @account.subscriptions.create!(plan: "starter", status: "trialing")
    @user = @account.users.create!(
      name: "Billing Owner",
      email: "billing-owner@staywise.test",
      role: "owner",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
  end

  test "subscription actions submit without turbo so stripe redirects work" do
    sign_in_as(@user)

    get subscription_path

    assert_response :success
    assert_select "form[data-turbo='false'] button", text: "Elegir Starter"
    assert_select "form[data-turbo='false'] button", text: "Abrir portal de suscripción"
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
