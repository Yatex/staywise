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

  test "settings exposes only profile and Copilot information" do
    sign_in_as(@user)

    get settings_path
    assert_response :success
    assert_select "nav[aria-label='Secciones de configuración'] a", count: 2
    assert_includes response.body, "Mi perfil"
    assert_includes response.body, "Cambio sensible"
    assert_not_includes response.body, "Número de WhatsApp"
    assert_not_includes response.body, "Modo observador"

    get settings_path(section: "ai")
    assert_response :success
    assert_includes response.body, "Ayla Copilot"
    assert_includes response.body, "Nunca envía respuestas"
    assert_select "form[action='#{settings_path}']", count: 0
  end

  test "owner can configure Copilot WhatsApp without changing legacy automation settings" do
    @account.update!(ai_active: true, owner_whatsapp_number: "+59899123456", observer_mode_enabled: false)
    sign_in_as(@user)

    patch settings_path, params: {
      section: "ai",
      account: { ai_active: "0", owner_whatsapp_number: "+59899123457", observer_mode_enabled: "1" }
    }

    assert_redirected_to settings_path(section: "ai")
    @account.reload
    assert @account.ai_active?
    assert_equal "+59899123457", @account.owner_whatsapp_number
    assert_not @account.observer_mode_enabled?
  end

  test "legacy co-host observer endpoints are gone" do
    co_host = @account.co_hosts.create!(name: "María", whatsapp_number: "+59899101010")
    sign_in_as(@user)

    patch co_host_observer_mode_path(co_host), params: { observer_mode_enabled: "1" }
    assert_response :gone
    assert_not co_host.reload.observer_mode_enabled?

    patch co_host_conversation_language_path(co_host), params: { preferred_conversation_language: "en" }
    assert_response :gone
  end

  test "owner can update their name" do
    sign_in_as(@user)

    patch settings_path, params: {
      user: {
        name: "New Owner Name"
      }
    }

    assert_redirected_to settings_path(section: "profile")
    assert_equal "New Owner Name", @user.reload.name
  end

  test "settings shows the official WhatsApp link and QR" do
    sign_in_as(@user)

    Whatsapp::HostCopilotDeepLink.stub(:call, "https://wa.me/15550009999?text=Hola%20Ayla") do
      Whatsapp::HostCopilotDeepLink.stub(:display_number, "+15550009999") do
        get settings_path
      end
    end

    assert_response :success
    assert_select "a[href^='https://wa.me/15550009999']", text: "Abrir WhatsApp"
    assert_select "img[src='#{whatsapp_copilot_qr_settings_path}'][alt='QR para hablar con Ayla por WhatsApp']"
    assert_includes response.body, "+15550009999"
  end

  test "authenticated user can load the WhatsApp Copilot QR" do
    sign_in_as(@user)
    svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>'

    Whatsapp::HostCopilotDeepLink.stub(:call, "https://wa.me/15550009999?text=Hola%20Ayla") do
      Whatsapp::HostCopilotQrCode.stub(:svg, svg) do
        get whatsapp_copilot_qr_settings_path
      end
    end

    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal svg, response.body
  end

  test "profile does not expose a separate conversation language preference" do
    sign_in_as(@user)

    get settings_path(locale: "en")

    assert_response :success
    assert_select "select[name='user[preferred_conversation_language]']", count: 0
    assert_not_includes response.body, "Preferred conversation language"
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

    assert_redirected_to settings_path(section: "profile")
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
