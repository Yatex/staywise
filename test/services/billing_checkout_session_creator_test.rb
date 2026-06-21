require "test_helper"

class BillingCheckoutSessionCreatorTest < ActiveSupport::TestCase
  setup do
    @previous_price_growth = ENV["STRIPE_PRICE_GROWTH"]
    @account = Account.create!(name: "Checkout Stays")
    @account.users.create!(
      name: "Owner",
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    @subscription = @account.subscriptions.create!(plan: "starter", status: "trialing")
    ENV["STRIPE_PRICE_GROWTH"] = "price_growth_test"
  end

  teardown do
    ENV["STRIPE_PRICE_GROWTH"] = @previous_price_growth
  end

  test "checkout params include subscription metadata and customer email for new stripe customers" do
    params = creator.send(:stripe_params)

    assert_equal "subscription", params["mode"]
    assert_equal "owner@example.com", params["customer_email"]
    assert_nil params["customer"]
    assert_equal @account.id, params["metadata[account_id]"]
    assert_equal "growth", params["metadata[plan]"]
    assert_equal @account.id, params["subscription_data[metadata][account_id]"]
    assert_equal "growth", params["subscription_data[metadata][plan]"]
    assert_equal "price_growth_test", params["line_items[0][price]"]
  end

  test "checkout params reuse existing stripe customer instead of sending customer email" do
    @subscription.update!(stripe_customer_id: "cus_existing")

    params = creator.send(:stripe_params)

    assert_equal "cus_existing", params["customer"]
    assert_nil params["customer_email"]
  end

  private

  def creator
    Billing::CheckoutSessionCreator.new(
      account: @account,
      plan: "growth",
      success_url: "https://staywise.test/subscriptions",
      cancel_url: "https://staywise.test/subscriptions"
    )
  end
end
