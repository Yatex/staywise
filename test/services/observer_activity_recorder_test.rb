require "test_helper"

class ObserverActivityRecorderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    @account = Account.create!(
      name: "Legacy observer account",
      owner_whatsapp_number: "+59899001001",
      observer_mode_enabled: true
    )
    @property = @account.properties.create!(name: "Legacy observer apartment")
    @guest = @account.guests.create!(property: @property, phone_number: "+59899002001")
    @conversation = @guest.conversations.create!(property: @property)
  end

  test "new messages do not record observer activity or enqueue notifications" do
    assert_no_enqueued_jobs only: ObserverNotificationJob do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Historical inbound")
      @conversation.messages.create!(sender: "ai", channel: "whatsapp", body: "Historical reply")
    end

    assert_empty @account.conversation_observer_activities
  end

  test "previously enqueued observer jobs are inert" do
    provider_called = false

    Whatsapp::ProviderFactory.stub(:build, -> { provider_called = true }) do
      ObserverNotificationJob.perform_now("Account", @account.id)
    end

    assert_not provider_called
    assert_empty @account.owner_whatsapp_sessions
  end

  test "historical observer data remains readable" do
    activity = @account.conversation_observer_activities.create!(
      account: @account,
      conversation: @conversation,
      property: @property,
      observer: @account,
      latest_message_direction: "guest",
      unread_activity_count: 2,
      last_activity_at: 1.day.ago
    )

    assert_equal 2, activity.reload.unread_activity_count
  end

  test "observer WhatsApp session model does not exist" do
    assert_nil defined?(ObserverWhatsappSession)
  end
end
