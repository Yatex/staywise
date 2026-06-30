require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Settings Stays")
    @account.subscriptions.create!(plan: "starter", status: "trialing")
    @user = @account.users.create!(
      name: "Settings Owner",
      email: "settings-owner@staywise.test",
      role: "owner",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  test "settings shows only user profile password fields and ai button" do
    sign_in_as(@user)

    get settings_path

    assert_response :success
    assert_includes response.body, "Tu nombre"
    assert_includes response.body, "Cambiar contraseña"
    assert_includes response.body, "Apagar AI"
    assert_no_match(/Nombre de la organización|Email|Proveedor de WhatsApp|Alertas urgentes|Asistente IA|Instrucciones de IA|Tono de voz|late_checkout_policy/, response.body)
  end

  test "owner can turn ai off for the account" do
    sign_in_as(@user)

    patch settings_path, params: {
      account: {
        name: @account.name,
        ai_active: "0"
      }
    }

    assert_redirected_to settings_path
    assert_not @account.reload.ai_active?
  end

  test "owner can update their name" do
    sign_in_as(@user)

    patch settings_path, params: {
      user: {
        name: "New Owner Name"
      }
    }

    assert_redirected_to settings_path
    assert_equal "New Owner Name", @user.reload.name
  end

  test "owner can change password with current password" do
    sign_in_as(@user)

    patch settings_path, params: {
      user: {
        name: @user.name,
        current_password: "password123",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      }
    }

    assert_redirected_to settings_path
    assert @user.reload.authenticate("newpassword123")
  end

  test "password change requires current password" do
    sign_in_as(@user)

    patch settings_path, params: {
      user: {
        name: @user.name,
        current_password: "wrong-password",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "La contraseña actual no es correcta."
    assert_not @user.reload.authenticate("newpassword123")
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
