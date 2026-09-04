require "test_helper"

class CopilotThreadTest < ActiveSupport::TestCase
  test "account property and user must share one tenant" do
    first = Account.create!(name: "First Tenant")
    first.subscriptions.create!(plan: "growth", status: "trialing")
    second = Account.create!(name: "Second Tenant")
    second.subscriptions.create!(plan: "growth", status: "trialing")
    user = first.users.create!(name: "Host", email: "tenant-host@example.test", password: "password123")
    property = second.properties.create!(name: "Foreign Property")

    thread = user.copilot_threads.new(account: first, property: property)

    assert_not thread.valid?
    assert_includes thread.errors[:property], "debe pertenecer a la cuenta"
  end
end
