require "test_helper"

class PropertiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Property Flow")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "property-owner@staywise.test",
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Step Apartment")

    sign_in_as(@user)
  end

  test "property show and step forms render" do
    get property_path(@property)
    assert_response :success
    assert_includes @response.body, "Dudas nuevas"

    get edit_property_path(@property)
    assert_response :success
    assert_includes @response.body, "Llegada y check-in"
    assert_includes @response.body, "Checkout"

    get new_property_knowledge_block_path(@property)
    assert_response :success
    assert_includes @response.body, "Link de YouTube opcional"
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
