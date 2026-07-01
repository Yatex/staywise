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
          password_confirmation: "password123",
          legal_acceptance: "1"
        }
      }
    end

    assert_redirected_to login_path
    user = User.find_by!(email: "new-owner@staywise.test")
    assert user.email_verification_required?
    assert user.email_verification_token.present?
    assert user.email_verification_sent_at.present?
    assert user.terms_accepted_at.present?
    assert user.privacy_accepted_at.present?
    assert_equal User::TERMS_VERSION, user.terms_version
    assert_equal User::PRIVACY_VERSION, user.privacy_version
  end

  test "signup requires terms and privacy acceptance" do
    assert_no_difference ["Account.count", "User.count"] do
      post signup_path, params: {
        registration: {
          account_name: "New Stays",
          name: "New Owner",
          email: "missing-legal@staywise.test",
          password: "password123",
          password_confirmation: "password123",
          legal_acceptance: "0"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "tenés que aceptar"
  end
end
