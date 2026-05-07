require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  test "root is public landing page" do
    get root_path

    assert_response :success
    assert_includes @response.body, "Staywise answers guest questions"
    assert_includes @response.body, signup_path
  end

  test "authenticated users are redirected from landing to dashboard" do
    account = Account.create!(name: "Landing Test")
    account.subscriptions.create!(plan: "starter", status: "trialing")
    user = account.users.create!(
      name: "Landing User",
      email: "landing-user@staywise.test",
      password: "password123",
      password_confirmation: "password123"
    )

    post login_path, params: { email: user.email, password: "password123" }
    get root_path

    assert_redirected_to dashboard_path
  end
end
