require "test_helper"

class AccountPropertyLimitOverrideTest < ActiveSupport::TestCase
  test "account without override uses its plan limit" do
    account = account_with_plan("business")

    assert_equal 20, account.plan_property_limit
    assert_equal 20, account.effective_property_limit
    assert_equal 20, account.property_limit
  end

  test "override including zero takes priority and removing it restores the plan limit" do
    account = account_with_plan("business")

    account.update!(property_limit_override: 0)
    assert_equal 0, account.effective_property_limit
    assert_not account.can_add_property?

    account.update!(property_limit_override: nil)
    assert_equal 20, account.effective_property_limit
    assert account.can_add_property?
  end

  test "override must be a non-negative integer" do
    account = account_with_plan("business")

    assert_not account.update(property_limit_override: -1)
    assert account.errors[:property_limit_override].any?
  end

  test "business with override 35 allows 35 properties without changing subscription" do
    account = account_with_plan("business")
    subscription = account.active_subscription
    subscription.update!(
      stripe_customer_id: "cus_override_test",
      stripe_subscription_id: "sub_override_test"
    )
    account.update!(property_limit_override: 35)

    35.times { |index| account.properties.create!(name: "Property #{index + 1}") }

    assert_not account.properties.new(name: "Property 36").valid?
    subscription.reload
    assert_equal "business", subscription.plan
    assert_equal "active", subscription.status
    assert_equal "cus_override_test", subscription.stripe_customer_id
    assert_equal "sub_override_test", subscription.stripe_subscription_id
  end

  test "plan changes never remove or override the administrative value" do
    account = account_with_plan("business")
    account.update!(property_limit_override: 35)

    account.active_subscription.update!(plan: "pro")

    assert_equal 60, account.plan_property_limit
    assert_equal 35, account.effective_property_limit
    assert_equal 35, account.property_limit_override
  end

  test "lowering the limit preserves existing properties and blocks new ones" do
    account = account_with_plan("business")
    3.times { |index| account.properties.create!(name: "Existing #{index + 1}") }

    account.update!(property_limit_override: 2)

    assert_equal 3, account.properties.count
    assert_not account.can_add_property?
    assert_not account.properties.new(name: "Blocked").valid?
    assert_equal 3, account.properties.count
  end

  private

  def account_with_plan(plan)
    account = Account.create!(name: "#{plan.titleize} Override #{SecureRandom.hex(4)}")
    account.subscriptions.create!(plan: plan, status: "active")
    account
  end
end
