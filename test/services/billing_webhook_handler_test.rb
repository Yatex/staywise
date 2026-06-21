require "test_helper"
require "json"
require "openssl"

class BillingWebhookHandlerTest < ActiveSupport::TestCase
  setup do
    @previous_webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]
    @previous_price_pro = ENV["STRIPE_PRICE_PRO"]
    @account = Account.create!(name: "Stripe Stays")
    @subscription = @account.subscriptions.create!(plan: "starter", status: "trialing", trial_ends_at: 14.days.from_now)
    ENV["STRIPE_WEBHOOK_SECRET"] = "whsec_test"
    ENV["STRIPE_PRICE_PRO"] = "price_pro_test"
  end

  teardown do
    ENV["STRIPE_WEBHOOK_SECRET"] = @previous_webhook_secret
    ENV["STRIPE_PRICE_PRO"] = @previous_price_pro
  end

  test "syncs checkout session into the existing trial subscription" do
    event = stripe_event(
      id: "evt_checkout",
      type: "checkout.session.completed",
      object: {
        "customer" => "cus_123",
        "subscription" => "sub_123",
        "status" => "complete",
        "client_reference_id" => @account.id,
        "metadata" => { "account_id" => @account.id, "plan" => "growth" }
      }
    )

    result = handle(event)

    assert result.fetch(:ok)
    assert_equal 1, @account.subscriptions.count
    @subscription.reload
    assert_equal "growth", @subscription.plan
    assert_equal "active", @subscription.status
    assert_equal "cus_123", @subscription.stripe_customer_id
    assert_equal "sub_123", @subscription.stripe_subscription_id
    assert_equal "evt_checkout", BillingEvent.last.stripe_event_id
  end

  test "syncs subscription update plan from stripe price id" do
    @subscription.update!(
      status: "active",
      stripe_customer_id: "cus_123",
      stripe_subscription_id: "sub_123"
    )
    period_end = 1.month.from_now.to_i
    event = stripe_event(
      id: "evt_subscription_updated",
      type: "customer.subscription.updated",
      object: {
        "id" => "sub_123",
        "customer" => "cus_123",
        "status" => "active",
        "current_period_end" => period_end,
        "metadata" => {},
        "items" => {
          "data" => [
            { "price" => { "id" => "price_pro_test" } }
          ]
        }
      }
    )

    result = handle(event)

    assert result.fetch(:ok)
    @subscription.reload
    assert_equal "pro", @subscription.plan
    assert_equal Time.at(period_end).to_i, @subscription.current_period_end.to_i
  end

  test "rejects unsigned stripe webhooks without webhook secret" do
    ENV["STRIPE_WEBHOOK_SECRET"] = nil

    result = Billing::WebhookHandler.new(payload: stripe_event.to_json, signature: nil).call

    assert_not result.fetch(:ok)
    assert_equal 0, BillingEvent.count
  end

  test "rejects expired stripe signatures" do
    event = stripe_event(id: "evt_expired")
    payload = event.to_json
    expired_timestamp = 10.minutes.ago.to_i

    result = Billing::WebhookHandler.new(
      payload: payload,
      signature: signature_for(payload, timestamp: expired_timestamp)
    ).call

    assert_not result.fetch(:ok)
    assert_equal 0, BillingEvent.count
  end

  private

  def handle(event)
    payload = event.to_json
    Billing::WebhookHandler.new(payload: payload, signature: signature_for(payload)).call
  end

  def stripe_event(id: "evt_test", type: "checkout.session.completed", object: {})
    {
      "id" => id,
      "type" => type,
      "data" => {
        "object" => object
      }
    }
  end

  def signature_for(payload, timestamp: Time.current.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("STRIPE_WEBHOOK_SECRET"), "#{timestamp}.#{payload}")
    "t=#{timestamp},v1=#{digest}"
  end
end
