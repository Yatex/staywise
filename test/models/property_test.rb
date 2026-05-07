require "test_helper"

class PropertyTest < ActiveSupport::TestCase
  test "starter plan limits account to one property" do
    account = Account.create!(name: "Starter Stays")
    account.subscriptions.create!(plan: "starter", status: "trialing")
    account.properties.create!(name: "First Apartment")

    second_property = account.properties.new(name: "Second Apartment")

    assert_not second_property.valid?
    assert_includes second_property.errors.full_messages.to_sentence, "current plan"
  end

  test "normalizes comma separated tags" do
    account = Account.create!(name: "Tagged Stays")
    account.subscriptions.create!(plan: "growth", status: "trialing")

    property = account.properties.create!(name: "Tagged Apartment", tag_list: " Beach, premium, beach ")

    assert_equal %w[beach premium], property.tags
    assert_equal [property], account.properties.tagged_with("beach").to_a
  end
end
