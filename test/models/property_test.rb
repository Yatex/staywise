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

  test "generates opaque public token for whatsapp reference" do
    account = Account.create!(name: "Token Stays")
    account.subscriptions.create!(plan: "growth", status: "trialing")

    property = account.properties.create!(name: "Private Apartment")

    assert_match(/\A[A-Za-z0-9]{24}\z/, property.public_token)
    assert_equal "Ayla stay #{property.public_token}", property.whatsapp_reference
    assert_not_includes property.whatsapp_reference, "##{property.id}"
  end

  test "soft deleted properties are hidden by default but retained in the database" do
    account = Account.create!(name: "Deleted Stays")
    account.subscriptions.create!(plan: "growth", status: "trialing")
    property = account.properties.create!(name: "Hidden Apartment")

    property.soft_delete!

    assert property.deleted?
    assert_nil Property.find_by(id: property.id)
    assert_nil account.properties.find_by(id: property.id)
    assert_equal property, Property.with_deleted.find(property.id)
    assert_includes Property.deleted, property
  end

  test "destroy is idempotent and never physically removes the property row" do
    account = Account.create!(name: "Idempotent Deletes")
    account.subscriptions.create!(plan: "growth", status: "trialing")
    property = account.properties.create!(name: "Idempotent Apartment")

    assert_no_difference -> { Property.with_deleted.count } do
      property.destroy
      property.destroy
    end

    assert Property.with_deleted.find(property.id).deleted?
  end

  test "historical records remain after property deletion" do
    account = Account.create!(name: "Historical Deletes")
    account.subscriptions.create!(plan: "growth", status: "trialing")
    property = account.properties.create!(name: "Historical Apartment", address: "History 123")
    guest = account.guests.create!(phone_number: "+15550101010", property: property)
    conversation = guest.conversations.create!(property: property, status: "active")
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "wifi?")
    trace = AIDecisionLog.create!(
      account: account,
      property: property,
      guest: guest,
      conversation: conversation,
      message: message,
      original_message: message,
      route: "remote_ai",
      decision: "reply",
      language: "es"
    )
    guest_request = GuestRequest.create!(
      account: account,
      property: property,
      conversation: conversation,
      guest: guest,
      message: message,
      guest_phone: guest.phone_number,
      property_name: property.display_name,
      property_address: property.address,
      category: "extra_item",
      title: "Más toallas",
      description: "Necesito más toallas",
      ai_summary: "El huésped pidió más toallas.",
      status: "pending",
      source_channel: "whatsapp"
    )

    property.destroy

    assert_equal conversation, Conversation.find(conversation.id)
    assert_equal message, Message.find(message.id)
    assert_equal trace, AIDecisionLog.find(trace.id)
    assert_equal guest_request, GuestRequest.find(guest_request.id)
    assert_equal property.id, Conversation.find(conversation.id).property_id
    assert_equal property.id, AIDecisionLog.find(trace.id).property_id
    assert_equal property.id, GuestRequest.find(guest_request.id).property_id
  end
end
