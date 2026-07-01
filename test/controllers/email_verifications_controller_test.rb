require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Verification Stays")
    @account.subscriptions.create!(plan: "starter", status: "trialing")
    @user = @account.users.create!(
      name: "Pending Owner",
      email: "pending-owner@staywise.test",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  test "verification link confirms user email" do
    assert @user.email_verification_required?

    get verify_email_path(token: @user.email_verification_token)

    assert_redirected_to login_path
    assert @user.reload.email_verified?
    assert_nil @user.email_verification_token
    assert_nil @user.email_verification_sent_at
  end

  test "invalid verification link redirects to login" do
    get verify_email_path(token: "not-a-real-token")

    assert_redirected_to login_path
    assert @user.reload.email_verification_required?
  end

  test "resend sends confirmation email without revealing accounts" do
    @user.update!(email_verification_sent_at: 2.days.ago)

    Notifications::EmailService.stub(:deliver, true) do
      post resend_verification_email_path, params: { email: @user.email }
    end

    assert_redirected_to login_path
    assert @user.reload.email_verification_sent_at > 1.minute.ago

    assert_nothing_raised do
      Notifications::EmailService.stub(:deliver, true) do
        post resend_verification_email_path, params: { email: "missing@staywise.test" }
      end
    end
    assert_redirected_to login_path
  end
end
