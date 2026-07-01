require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "signup creates an unverified user and sends confirmation email" do
    Notifications::EmailService.stub(:deliver, true) do
      post signup_path, params: {
        registration: {
          account_name: "New Stays",
          name: "New Owner",
          email: "new-owner@staywise.test",
          password: "password123",
          password_confirmation: "password123"
        }
      }
    end

    assert_redirected_to login_path
    user = User.find_by!(email: "new-owner@staywise.test")
    assert user.email_verification_required?
    assert user.email_verification_token.present?
    assert user.email_verification_sent_at.present?
  end
end
