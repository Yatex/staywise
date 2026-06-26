require "test_helper"

class PropertyTest < ActiveSupport::TestCase
  test "starter plan limits account to three properties" do
    account = Account.create!(name: "Starter Stays")
    account.subscriptions.create!(plan: "starter", status: "trialing")
    3.times { |index| account.properties.create!(name: "Apartment #{index + 1}") }

    fourth_property = account.properties.new(name: "Fourth Apartment")

    assert_not fourth_property.valid?
    assert_includes fourth_property.errors.full_messages.to_sentence, "current plan"
  end

  test "normalizes comma separated tags" do
    account = Account.create!(name: "Tagged Stays")
    account.subscriptions.create!(plan: "growth", status: "trialing")

    property = account.properties.create!(name: "Tagged Apartment", tag_list: " Beach, premium, beach ")

    assert_equal %w[beach premium], property.tags
    assert_equal [property], account.properties.tagged_with("beach").to_a
  end
end
