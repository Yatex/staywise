require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "unverified users cannot sign in and receive a new verification email" do
    account = Account.create!(name: "Login Verification")
    account.subscriptions.create!(plan: "starter", status: "trialing")
    user = account.users.create!(
      name: "Unverified Owner",
      email: "unverified-owner@staywise.test",
      password: "password123",
      password_confirmation: "password123"
    )

    Notifications::EmailService.stub(:deliver, true) do
      post login_path, params: { email: user.email, password: "password123" }
    end

    assert_redirected_to login_path
    assert user.reload.email_verification_required?
    assert user.email_verification_sent_at.present?
  end

  test "invalid sign in renders auto dismissable toast" do
    post login_path, params: { email: "missing@staywise.test", password: "wrong-password" }

    assert_response :unprocessable_entity
    assert_includes @response.body, "El email o la contraseña son incorrectos."
    assert_includes @response.body, 'data-controller="dismissable"'
    assert_includes @response.body, 'data-dismissable-timeout-value="3500"'
  end
end
