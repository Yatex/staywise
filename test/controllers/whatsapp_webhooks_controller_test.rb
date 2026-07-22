require "test_helper"

class WhatsappWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_provider = ENV["WHATSAPP_PROVIDER"]
    @previous_auth_token = ENV["TWILIO_AUTH_TOKEN"]
    @account = Account.create!(name: "Webhook Controller Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Webhook Controller Apartment")
  end

  teardown do
    ENV["WHATSAPP_PROVIDER"] = @previous_provider
    ENV["TWILIO_AUTH_TOKEN"] = @previous_auth_token
  end

  test "rejects twilio webhooks with invalid signatures" do
    ENV["WHATSAPP_PROVIDER"] = "twilio"
    ENV["TWILIO_AUTH_TOKEN"] = "secret-token"

    assert_difference "OperationalError.where(source: 'whatsapp_webhook', severity: 'warning').count", 1 do
      post webhooks_whatsapp_path,
        params: whatsapp_payload,
        headers: { "X-Twilio-Signature" => "invalid" }
    end

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

  test "asks for property qr when webhook has no property context" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil

    post webhooks_whatsapp_path, params: whatsapp_payload(body: "Can I get late checkout?")

    assert_response :success
    assert_equal "missing_property_context", response.parsed_body["error"]
    assert_nil response.parsed_body["conversation_id"]
    assert_equal 0, Conversation.count
  end

  test "acknowledges an empty or unsupported inbound event without creating a critical error" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil

    assert_no_difference ["Conversation.count", "OperationalError.where(source: 'whatsapp_webhook').count"] do
      post webhooks_whatsapp_path, params: whatsapp_payload(body: "").merge(
        "MessageSid" => "SM_EMPTY_EVENT",
        "MessageType" => "location",
        "Latitude" => "-34.9",
        "Longitude" => "-56.2"
      )
    end

    assert_response :success
    assert_equal true, response.parsed_body["ok"]
    assert_equal true, response.parsed_body["ignored"]
    assert_equal "empty_or_unsupported_message", response.parsed_body["error"]
  end

  test "acknowledges a repeated guest MessageSid without processing the message twice" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil
    payload = whatsapp_payload.merge("MessageSid" => "SM_REPEATED_GUEST")

    post webhooks_whatsapp_path, params: payload
    assert_response :success

    assert_no_difference ["Message.count", "Conversation.count"] do
      post webhooks_whatsapp_path, params: payload
    end

    assert_response :success
    assert_equal true, response.parsed_body["duplicate"]
    assert_equal 1, Message.where("metadata ->> 'MessageSid' = ?", "SM_REPEATED_GUEST").count
  end

  private

  def whatsapp_payload(body: "#{@property.whatsapp_reference} Can I get late checkout?")
    {
      "From" => "whatsapp:+15550000008",
      "To" => "whatsapp:+15550009999",
      "Body" => body
    }
  end
end
