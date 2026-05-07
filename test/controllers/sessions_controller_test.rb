require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "invalid sign in renders auto dismissable toast" do
    post login_path, params: { email: "missing@staywise.test", password: "wrong-password" }

    assert_response :unprocessable_entity
    assert_includes @response.body, "Email or password is incorrect."
    assert_includes @response.body, 'data-controller="dismissable"'
    assert_includes @response.body, 'data-dismissable-timeout-value="3500"'
  end
end
