require "test_helper"

class WhatsappIncomingMessageHandlerTest < ActiveSupport::TestCase
  class FailingProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:)
      false
    end
  end

  setup do
    @account = Account.create!(name: "Webhook Stays")
    @account.update!(email_alerts_enabled: false)
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Webhook Apartment")
  end

  teardown do
  end

  test "creates guest conversation messages and alert from incoming whatsapp payload" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000002",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} Can I get late checkout?"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    conversation = result.fetch(:conversation)

    assert result.fetch(:replied)
    assert_equal "escalated", conversation.reload.status
    assert_equal "+15550000002", conversation.guest.phone_number
    assert_equal 2, conversation.messages.count
    assert_equal "late_checkout_request", conversation.alerts.first.alert_type
  end

  test "does not store an ai message when whatsapp delivery fails" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000003",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} Can I get late checkout?"
      },
      provider: FailingProvider.new
    ).call

    conversation = result.fetch(:conversation)

    assert_not result.fetch(:replied)
    assert_equal 1, conversation.messages.count
    assert_equal ["guest"], conversation.messages.pluck(:sender)
  end

  test "english emergency phrase creates urgent alert without ai service" do
    previous_ai_service_url = ENV["AI_SERVICE_URL"]
    ENV["AI_SERVICE_URL"] = "http://127.0.0.1:1"
    @property.update!(emergency_information: "Call 911 first, then contact the host.")

    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000004",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} There is smoke in the apartment, emergency"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    alert = result.fetch(:conversation).alerts.first

    assert result.fetch(:replied)
    assert_equal "emergency", alert.alert_type
    assert_equal "urgent", alert.priority
    assert_includes result.fetch(:conversation).messages.where(sender: "ai").last.body, "911"
  ensure
    ENV["AI_SERVICE_URL"] = previous_ai_service_url
  end

  test "spanish emergency phrase creates urgent alert" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000005",
        "To" => "whatsapp:+15550009999",
        "Body" => "#{@property.whatsapp_reference} Hay una fuga de gas"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    alert = result.fetch(:conversation).alerts.first

    assert_equal "emergency", alert.alert_type
    assert_equal "urgent", alert.priority
  end

  test "asks unknown guests to scan property qr instead of using a default property" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000006",
        "To" => "whatsapp:+15550009999",
        "Body" => "What is the wifi password?"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert result.fetch(:replied)
    assert_equal "missing_property_context", result.fetch(:error)
    assert_nil result.fetch(:conversation)
    assert_equal 0, Conversation.count
    assert_equal 0, Message.count
  end

  test "routes returning guest without qr to their previous property" do
    guest = @account.guests.create!(phone_number: "+15550000007", property: @property)
    guest.conversations.create!(property: @property, status: "active", ai_enabled: true)

    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000007",
        "To" => "whatsapp:+15550009999",
        "Body" => "Can I get late checkout?"
      },
      provider: Whatsapp::Providers::NullProvider.new
    ).call

    assert result.fetch(:replied)
    assert_equal @property, result.fetch(:conversation).property
    assert_equal "late_checkout_request", result.fetch(:conversation).alerts.first.alert_type
  end
end
