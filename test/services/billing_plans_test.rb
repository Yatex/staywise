require "test_helper"

class BillingPlansTest < ActiveSupport::TestCase
  setup do
    @previous_scale = ENV["STRIPE_PRICE_SCALE"]
    @previous_pro = ENV["STRIPE_PRICE_PRO"]
    @previous_business = ENV["STRIPE_PRICE_BUSINESS"]
  end

  teardown do
    ENV["STRIPE_PRICE_SCALE"] = @previous_scale
    ENV["STRIPE_PRICE_PRO"] = @previous_pro
    ENV["STRIPE_PRICE_BUSINESS"] = @previous_business
  end

  test "maps display plan names scale and pro to their price envs" do
    ENV["STRIPE_PRICE_SCALE"] = "price_scale"
    ENV["STRIPE_PRICE_PRO"] = "price_pro"
    ENV["STRIPE_PRICE_BUSINESS"] = nil

    assert_equal "price_scale", Billing::Plans.price_id_for("pro")
    assert_equal "price_pro", Billing::Plans.price_id_for("business")
    assert_equal "pro", Billing::Plans.plan_for_price_id("price_scale")
    assert_equal "business", Billing::Plans.plan_for_price_id("price_pro")
  end

  test "keeps legacy business env support" do
    ENV["STRIPE_PRICE_SCALE"] = nil
    ENV["STRIPE_PRICE_PRO"] = "price_scale_legacy"
    ENV["STRIPE_PRICE_BUSINESS"] = "price_business_legacy"

    assert_equal "price_scale_legacy", Billing::Plans.price_id_for("pro")
    assert_equal "price_business_legacy", Billing::Plans.price_id_for("business")
  end
end
