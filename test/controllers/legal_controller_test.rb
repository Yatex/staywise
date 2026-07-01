require "test_helper"

class LegalControllerTest < ActionDispatch::IntegrationTest
  test "terms are public" do
    get terms_path

    assert_response :success
    assert_includes response.body, "Términos y Condiciones"
    assert_includes response.body, User::TERMS_VERSION
  end

  test "privacy policy is public" do
    get privacy_path

    assert_response :success
    assert_includes response.body, "Política de Privacidad"
    assert_includes response.body, User::PRIVACY_VERSION
  end
end
