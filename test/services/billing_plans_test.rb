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

  test "maps all plans to their own stripe price envs" do
    ENV["STRIPE_PRICE_SCALE"] = "price_scale"
    ENV["STRIPE_PRICE_PRO"] = "price_pro"
    ENV["STRIPE_PRICE_BUSINESS"] = "price_business"

    assert_equal "price_business", Billing::Plans.price_id_for("business")
    assert_equal "price_scale", Billing::Plans.price_id_for("scale")
    assert_equal "price_pro", Billing::Plans.price_id_for("pro")
    assert_equal "business", Billing::Plans.plan_for_price_id("price_business")
    assert_equal "scale", Billing::Plans.plan_for_price_id("price_scale")
    assert_equal "pro", Billing::Plans.plan_for_price_id("price_pro")
  end

  test "exposes the requested prices and property limits" do
    definitions = Billing::Plans.all.index_by { |plan| plan[:id] }

    assert_equal "USD 15/mes", definitions.fetch("starter")[:price]
    assert_equal "USD 39/mes", definitions.fetch("growth")[:price]
    assert_equal "USD 59/mes", definitions.fetch("business")[:price]
    assert_equal "USD 89/mes", definitions.fetch("scale")[:price]
    assert_equal "USD 149/mes", definitions.fetch("pro")[:price]
    assert_equal({ "starter" => 3, "growth" => 10, "business" => 20, "scale" => 35, "pro" => 60 }, Subscription::PLAN_LIMITS)
  end
end
