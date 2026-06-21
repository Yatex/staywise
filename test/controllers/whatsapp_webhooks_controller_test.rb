require "test_helper"

class WhatsappWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_provider = ENV["WHATSAPP_PROVIDER"]
    @previous_auth_token = ENV["TWILIO_AUTH_TOKEN"]
    @previous_default_account_id = ENV["DEFAULT_ACCOUNT_ID"]
    @account = Account.create!(name: "Webhook Controller Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @account.properties.create!(name: "Webhook Controller Apartment")
    ENV["DEFAULT_ACCOUNT_ID"] = @account.id.to_s
  end

  teardown do
    ENV["WHATSAPP_PROVIDER"] = @previous_provider
    ENV["TWILIO_AUTH_TOKEN"] = @previous_auth_token
    ENV["DEFAULT_ACCOUNT_ID"] = @previous_default_account_id
  end

  test "rejects twilio webhooks with invalid signatures" do
    ENV["WHATSAPP_PROVIDER"] = "twilio"
    ENV["TWILIO_AUTH_TOKEN"] = "secret-token"

    post webhooks_whatsapp_path,
      params: whatsapp_payload,
      headers: { "X-Twilio-Signature" => "invalid" }

    assert_response :unauthorized
    assert_equal 0, Conversation.count
  end

  test "accepts webhook without twilio signature when provider is not twilio" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil

    post webhooks_whatsapp_path, params: whatsapp_payload

    assert_response :success
    assert_equal 1, Conversation.count
  end

  private

  def whatsapp_payload
    {
      "From" => "whatsapp:+15550000008",
      "To" => "whatsapp:+15550009999",
      "Body" => "Can I get late checkout?"
    }
  end
end
