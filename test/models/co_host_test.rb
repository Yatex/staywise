require "test_helper"

class CoHostTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Co-host model", owner_whatsapp_number: "+59899000001", owner_whatsapp_escalations_enabled: true)
    @property = @account.properties.create!(name: "Property A")
  end

  test "a property can have no co-host or exactly one" do
    assert_nil @property.co_host
    co_host = @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899000002")
    @property.update!(co_host: co_host)

    assert_equal co_host, @property.reload.co_host
    assert_raises(ActiveRecord::RecordInvalid) do
      other_account = Account.create!(name: "Other")
      @property.update!(co_host: other_account.co_hosts.create!(name: "Wrong", whatsapp_number: "+59899000003"))
    end
  end

  test "the same co-host can manage several properties of one owner" do
    co_host = @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899000002")
    other_property = @account.properties.create!(name: "Property B")
    @property.update!(co_host: co_host)
    other_property.update!(co_host: co_host)

    assert_equal [@property.id, other_property.id].sort, co_host.properties.pluck(:id).sort
  end

  test "different properties can have different co-hosts" do
    other_property = @account.properties.create!(name: "Property B")
    first = @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899000002")
    second = @account.co_hosts.create!(name: "Pedro", whatsapp_number: "+59899000003")
    @property.update!(co_host: first)
    other_property.update!(co_host: second)

    assert_equal first, @property.co_host
    assert_equal second, other_property.co_host
  end

  test "phone identity cannot collide with an owner or another account" do
    collision = @account.co_hosts.new(name: "Owner duplicate", whatsapp_number: @account.owner_whatsapp_number)
    assert_not collision.valid?

    @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899000002")
    other = Account.create!(name: "Other")
    duplicate = other.co_hosts.new(name: "Same phone", whatsapp_number: "+59899000002")
    assert_not duplicate.valid?
  end

  test "authorization is revoked and reassigned immediately" do
    first = @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899000002")
    second = @account.co_hosts.create!(name: "Pedro", whatsapp_number: "+59899000003")
    @property.update!(co_host: first)
    owner_actor = Whatsapp::HostActor.owner(@account)
    first_actor = Whatsapp::HostActor.co_host(first)
    second_actor = Whatsapp::HostActor.co_host(second)

    assert owner_actor.can_manage_property?(@property)
    assert first_actor.can_manage_property?(@property)
    assert_not second_actor.can_manage_property?(@property)

    @property.update!(co_host: second)
    assert_not first_actor.can_manage_property?(@property.reload)
    assert second_actor.can_manage_property?(@property)
  end

  test "removal preserves co-host history but revokes inbound authorization" do
    co_host = @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899000002")
    @property.update!(co_host: co_host)
    assert Whatsapp::HostActor.authorized_phone?(co_host.whatsapp_number)

    Properties::CoHostAssignment.call(property: @property, name: "", phone_number: "")

    assert CoHost.exists?(co_host.id)
    assert_not Whatsapp::HostActor.authorized_phone?(co_host.whatsapp_number)
    assert_not Whatsapp::HostActor.co_host(co_host).can_manage_property?(@property.reload)
  end
end
