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

  test "main sidebar does not expose recommendations as a top-level section" do
    get dashboard_path

    assert_response :success
    assert_select "aside nav a", text: "Recomendaciones", count: 0
  end

  test "owner manages recommendations from a property" do
    property = @account.properties.create!(name: "Local Guide")

    get property_path(property)

    assert_response :success
    assert_includes response.body, "Recomendaciones locales"
    assert_includes response.body, new_property_recommendation_path(property)

    assert_difference -> { property.recommendations.count }, 1 do
      post property_recommendations_path(property), params: {
        recommendation: {
          name: "Café del Sol",
          category: "cafe",
          description: "Buen café cerca.",
          address: "Calle 123"
        }
      }
    end

    recommendation = property.recommendations.order(:created_at).last
    assert_redirected_to property_path(property)

    patch property_recommendation_path(property, recommendation), params: {
      recommendation: {
        name: "Café del Sol",
        category: "cafe",
        description: "Buen desayuno cerca.",
        address: "Calle 123"
      }
    }
    assert_redirected_to property_path(property)
    assert_equal "Buen desayuno cerca.", recommendation.reload.description

    assert_difference -> { property.recommendations.count }, -1 do
      delete property_recommendation_path(property, recommendation)
    end
    assert_redirected_to property_path(property)
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
