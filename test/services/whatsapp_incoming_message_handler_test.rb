require "test_helper"

class WhatsappIncomingMessageHandlerTest < ActiveSupport::TestCase
  class FailingProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:)
      false
    end
  end

  setup do
    @previous_default_account_id = ENV["DEFAULT_ACCOUNT_ID"]
    @account = Account.create!(name: "Webhook Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Webhook Apartment")
    ENV["DEFAULT_ACCOUNT_ID"] = @account.id.to_s
  end

  teardown do
    ENV["DEFAULT_ACCOUNT_ID"] = @previous_default_account_id
  end

  test "creates guest conversation messages and alert from incoming whatsapp payload" do
    result = Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:+15550000002",
        "To" => "whatsapp:+15550009999",
        "Body" => "Can I get late checkout?"
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
        "Body" => "Can I get late checkout?"
      },
      provider: FailingProvider.new
    ).call

    conversation = result.fetch(:conversation)

    assert_not result.fetch(:replied)
    assert_equal 1, conversation.messages.count
    assert_equal ["guest"], conversation.messages.pluck(:sender)
  end
end
