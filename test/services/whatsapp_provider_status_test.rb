require "test_helper"

class WhatsappProviderStatusTest < ActiveSupport::TestCase
  setup do
    @previous_provider = ENV["WHATSAPP_PROVIDER"]
    @previous_sid = ENV["TWILIO_ACCOUNT_SID"]
    @previous_token = ENV["TWILIO_AUTH_TOKEN"]
    @previous_from = ENV["TWILIO_WHATSAPP_FROM"]
  end

  teardown do
    ENV["WHATSAPP_PROVIDER"] = @previous_provider
    ENV["TWILIO_ACCOUNT_SID"] = @previous_sid
    ENV["TWILIO_AUTH_TOKEN"] = @previous_token
    ENV["TWILIO_WHATSAPP_FROM"] = @previous_from
  end

  test "is configured only when twilio provider has all required env vars" do
    ENV["WHATSAPP_PROVIDER"] = "twilio"
    ENV["TWILIO_ACCOUNT_SID"] = "AC123"
    ENV["TWILIO_AUTH_TOKEN"] = "token"
    ENV["TWILIO_WHATSAPP_FROM"] = "whatsapp:+15550009999"

    assert Whatsapp::ProviderStatus.configured?
    assert_equal "Proveedor activo", Whatsapp::ProviderStatus.label
  end

  test "is not configured for null provider" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_ACCOUNT_SID"] = "AC123"
    ENV["TWILIO_AUTH_TOKEN"] = "token"
    ENV["TWILIO_WHATSAPP_FROM"] = "whatsapp:+15550009999"

    assert_not Whatsapp::ProviderStatus.configured?
    assert_equal "Proveedor no conectado", Whatsapp::ProviderStatus.label
  end
end
