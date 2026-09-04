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

  test "guest inbound is acknowledged but cannot create conversations, effects or replies" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil

    assert_no_difference ["Conversation.count", "Message.count", "OwnerTask.count", "Alert.count"] do
      post webhooks_whatsapp_path, params: whatsapp_payload
    end

    assert_response :success
    assert_equal true, response.parsed_body["ignored"]
    assert_equal false, response.parsed_body["replied"]
    assert_equal "guest_whatsapp_channel_retired", response.parsed_body["error"]
    assert_equal "external", response.parsed_body["channel"]
  end

  test "property tokens no longer reactivate the retired guest channel" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil

    post webhooks_whatsapp_path, params: whatsapp_payload(body: "Can I get late checkout?")

    assert_response :success
    assert_equal "guest_whatsapp_channel_retired", response.parsed_body["error"]
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
    assert_equal "guest_whatsapp_channel_retired", response.parsed_body["error"]
  end

  test "repeated guest MessageSid remains side effect free" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    ENV["TWILIO_AUTH_TOKEN"] = nil
    payload = whatsapp_payload.merge("MessageSid" => "SM_REPEATED_GUEST")

    post webhooks_whatsapp_path, params: payload
    assert_response :success

    assert_no_difference ["Message.count", "Conversation.count"] do
      post webhooks_whatsapp_path, params: payload
    end

    assert_response :success
    assert_equal true, response.parsed_body["ignored"]
    assert_equal 0, Message.where("metadata ->> 'MessageSid' = ?", "SM_REPEATED_GUEST").count
  end

  test "host inbound is classified separately but does not enter the legacy owner workflow" do
    ENV["WHATSAPP_PROVIDER"] = "null"
    @account.update!(owner_whatsapp_number: "+15550000008")

    assert_no_difference ["OwnerWhatsappSession.count", "CopilotThread.count", "Message.count"] do
      post webhooks_whatsapp_path, params: whatsapp_payload(body: "Necesito ayuda con una respuesta")
    end

    assert_response :success
    assert_equal "host", response.parsed_body["channel"]
    assert_equal "host_whatsapp_copilot_not_enabled", response.parsed_body["error"]
    assert_equal false, response.parsed_body["replied"]
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
