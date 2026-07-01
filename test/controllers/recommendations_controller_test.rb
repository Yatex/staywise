require "test_helper"

class RecommendationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Recommendations Test")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "recommendations-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    sign_in_as(@user)
  end

  test "recommendations page renders clean spanish copy by default" do
    get recommendations_path

    assert_response :success
    assert_includes response.body, "Todos los lugares aprobados por el anfitrión"
    assert_includes response.body, "Abrí una propiedad"
    assert_not_includes response.body, "host-approved"
    assert_not_includes response.body, "Open a property"
  end

  test "recommendations page can switch to english" do
    get recommendations_path(locale: "en")

    assert_response :success
    assert_includes response.body, "All host-approved places across your properties."
    assert_includes response.body, "Open a property"
    assert_not_includes response.body, "propiedades"
    assert_select "a", text: "EN"
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
