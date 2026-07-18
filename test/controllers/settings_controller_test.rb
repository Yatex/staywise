require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Settings Stays")
    @account.subscriptions.create!(plan: "starter", status: "trialing")
    @user = @account.users.create!(
      name: "Settings Owner",
      email: "settings-owner@staywise.test",
      role: "owner",
      email_verified_at: Time.current,
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

  test "settings warns when owner whatsapp is not configured" do
    sign_in_as(@user)

    get settings_path

    assert_response :success
    assert_select "[data-testid='owner-whatsapp-warning']", 1
    assert_includes response.body, "WhatsApp del anfitrión sin configurar"
    assert_includes response.body, "Ingresá el número del anfitrión"
  end

  test "settings warns when owner whatsapp has a number but notifications are disabled" do
    @account.update!(owner_whatsapp_number: "+59899123456", owner_whatsapp_escalations_enabled: false)
    sign_in_as(@user)

    get settings_path

    assert_response :success
    assert_select "[data-testid='owner-whatsapp-warning']", 1
    assert_includes response.body, "Activá las notificaciones"
  end

  test "settings hides owner whatsapp warning when notifications are configured" do
    @account.update!(owner_whatsapp_number: "+59899123456", owner_whatsapp_escalations_enabled: true)
    sign_in_as(@user)

    get settings_path

    assert_response :success
    assert_select "[data-testid='owner-whatsapp-warning']", 0
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

  test "owner can enable and disable observer mode" do
    sign_in_as(@user)

    patch settings_path, params: { account: { observer_mode_enabled: "1" } }
    assert_redirected_to settings_path
    assert @account.reload.observer_mode_enabled?
    assert @account.observer_mode_activated_at.present?

    patch settings_path, params: { account: { observer_mode_enabled: "0" } }
    assert_redirected_to settings_path
    assert_not @account.reload.observer_mode_enabled?
  end

  test "member cannot change observer mode" do
    member = @account.users.create!(
      name: "Settings Member",
      email: "settings-member@staywise.test",
      role: "member",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    sign_in_as(member)

    patch settings_path, params: { account: { observer_mode_enabled: "1" } }

    assert_response :forbidden
    assert_not @account.reload.observer_mode_enabled?
  end

  test "owner can configure a co-host observer preference independently" do
    co_host = @account.co_hosts.create!(name: "María", whatsapp_number: "+59899101010")
    sign_in_as(@user)

    patch co_host_observer_mode_path(co_host), params: { observer_mode_enabled: "1" }

    assert_redirected_to settings_path
    assert co_host.reload.observer_mode_enabled?
    assert_not @account.reload.observer_mode_enabled?
  end

  test "member cannot configure co-host observer preference" do
    co_host = @account.co_hosts.create!(name: "María", whatsapp_number: "+59899101011")
    member = @account.users.create!(
      name: "Settings Member Two",
      email: "settings-member-two@staywise.test",
      role: "member",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    sign_in_as(member)

    patch co_host_observer_mode_path(co_host), params: { observer_mode_enabled: "1" }

    assert_response :forbidden
    assert_not co_host.reload.observer_mode_enabled?
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
