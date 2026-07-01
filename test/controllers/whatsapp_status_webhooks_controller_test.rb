require "test_helper"

class WhatsappStatusWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_provider = ENV["WHATSAPP_PROVIDER"]
    ENV["WHATSAPP_PROVIDER"] = "null"

    @account = Account.create!(name: "Status Webhook Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Status Apartment")
    @guest = @account.guests.create!(phone_number: "+15550003000", property: @property)
    @conversation = @guest.conversations.create!(property: @property, status: "escalated")
    @message = @conversation.messages.create!(
      sender: "owner",
      channel: "whatsapp",
      body: "Respuesta del propietario.",
      metadata: {
        "provider_message_id" => "SM_status_test",
        "delivery_status" => "queued"
      }
    )
  end

  teardown do
    ENV["WHATSAPP_PROVIDER"] = @previous_provider
  end

  test "updates message delivery status from twilio callback" do
    post webhooks_whatsapp_status_path, params: {
      "MessageSid" => "SM_status_test",
      "MessageStatus" => "delivered"
    }

    assert_response :success
    assert_equal "delivered", @message.reload.metadata["delivery_status"]
    assert @message.metadata["delivery_status_updated_at"].present?
  end

  test "reports operational error when twilio cannot deliver owner reply" do
    assert_difference "OperationalError.where(source: 'twilio_provider', severity: 'error').count", 1 do
      post webhooks_whatsapp_status_path, params: {
        "MessageSid" => "SM_status_test",
        "MessageStatus" => "undelivered",
        "ErrorCode" => "63016",
        "ErrorMessage" => "Failed to deliver"
      }
    end

    assert_response :success
    assert_equal "undelivered", @message.reload.metadata["delivery_status"]
    assert_equal "63016", @message.metadata["delivery_error_code"]
  end
end
