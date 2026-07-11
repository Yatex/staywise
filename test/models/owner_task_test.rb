require "test_helper"

class OwnerTaskTest < ActiveSupport::TestCase
  setup do
    account = Account.create!(name: "Owner Tasks")
    property = account.properties.create!(name: "Task Apartment")
    guest = account.guests.create!(phone_number: "+15550007777", property: property)
    conversation = guest.conversations.create!(property: property)
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Necesito ayuda")
    @attributes = {
      account: account, property: property, guest: guest, conversation: conversation, message: message,
      guest_phone: guest.phone_number, property_name: property.display_name, category: "other",
      title: "Tarea", description: message.body, status: "pending", priority: "normal", source_channel: "whatsapp"
    }
  end

  test "accepts only explicit request and inquiry kinds" do
    assert_equal "request", OwnerTask.create!(@attributes.merge(kind: "request")).kind
    inquiry = OwnerTask.new(@attributes.merge(kind: "invalid"))
    assert_not inquiry.valid?
    assert inquiry.errors[:kind].present?
  end

  test "database rejects invalid kind even without model validation" do
    task = OwnerTask.create!(@attributes.merge(kind: "inquiry"))
    assert_raises(ActiveRecord::StatementInvalid) do
      OwnerTask.where(id: task.id).update_all(kind: "invalid")
    end
  end
end
