require "test_helper"

class PropertyLimitConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Property limit concurrency #{SecureRandom.hex(5)}", property_limit_override: 1)
    @account.subscriptions.create!(plan: "business", status: "active")
  end

  teardown do
    Property.with_deleted.where(account_id: @account.id).delete_all
    @account.subscriptions.delete_all
    @account.delete
  end

  test "concurrent creations cannot exceed the effective limit" do
    ready = Queue.new
    start = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Property.create(account_id: @account.id, name: "Concurrent #{index}")
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)

    assert_equal 1, results.count(&:persisted?)
    assert_equal 1, results.count { |property| property.errors.any? }
    assert_equal 1, @account.properties.count
  end
end
