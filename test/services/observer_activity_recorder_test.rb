require "test_helper"

class ObserverActivityRecorderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :templates, :messages

    def initialize
      @templates = []
      @messages = []
    end

    def send_template(to:, template_sid:, variables: {})
      @templates << { to: to, template_sid: template_sid, variables: variables }
      true
    end

    def send_message(to:, body:, media_urls: [])
      @messages << { to: to, body: body }
      true
    end
  end

  class FailingProvider < RecordingProvider
    def send_template(to:, template_sid:, variables: {})
      DeliveryResult.new(success?: false, error: "Twilio observer delivery failed")
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    @previous_sid = ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
    @previous_host = ENV["APP_HOST"]
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = "HX_OBSERVER"
    ENV["APP_HOST"] = "https://ayla.test"
    @account = Account.create!(name: "Observer account", owner_whatsapp_number: "+59899001001", observer_mode_enabled: true)
    @property = @account.properties.create!(name: "Observer apartment")
    @guest = @account.guests.create!(property: @property, phone_number: "+59899002001", name: "Juan")
    @conversation = @guest.conversations.create!(property: @property)
    @provider = RecordingProvider.new
  end

  teardown do
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = @previous_sid
    ENV["APP_HOST"] = @previous_host
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "observer mode is disabled by default" do
    account = Account.create!(name: "Observer disabled")
    co_host = account.co_hosts.create!(name: "Co-host", whatsapp_number: "+59899003001")

    assert_not account.observer_mode_enabled?
    assert_not co_host.observer_mode_enabled?
  end

  test "disabled observer mode does not record or enqueue activity" do
    @account.update!(observer_mode_enabled: false)

    assert_no_enqueued_jobs only: ObserverNotificationJob do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje sin observador")
    end

    assert_empty @account.conversation_observer_activities
  end

  test "guest ai and owner messages update activity and only enqueue notifications" do
    assert_enqueued_jobs 3, only: ObserverNotificationJob do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Cómo entro?")
      @conversation.messages.create!(sender: "ai", channel: "whatsapp", body: "Usá el código indicado.")
      @conversation.messages.create!(sender: "owner", channel: "dashboard", body: "Te ayudo desde Ayla.")
    end

    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    assert_equal 3, activity.unread_activity_count
    assert_equal "owner", activity.latest_message_direction
    assert_empty @provider.templates
  end

  test "notification waits for a quiet window and includes guest property and direct link" do
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Cómo entro?")

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      ObserverNotificationJob.perform_now("Account", @account.id)
    end
    assert_empty @provider.templates
    assert_enqueued_jobs 2, only: ObserverNotificationJob

    @account.conversation_observer_activities.update_all(last_activity_at: 6.minutes.ago)
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      ObserverNotificationJob.perform_now("Account", @account.id)
    end

    assert_equal 1, @provider.templates.size
    template = @provider.templates.first
    assert_equal "HX_OBSERVER", template[:template_sid]
    assert_includes template.dig(:variables, "1"), "Juan"
    assert_includes template.dig(:variables, "1"), "Observer apartment"
    assert_equal "https://ayla.test/conversations/#{@conversation.id}", template.dig(:variables, "2")
  end

  test "many messages and conversations produce one aggregated notification" do
    other_guest = @account.guests.create!(property: @property, phone_number: "+59899002002", name: "Ana")
    other_conversation = other_guest.conversations.create!(property: @property)
    5.times { |index| @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Primera #{index}") }
    3.times { |index| other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Segunda #{index}") }
    @account.conversation_observer_activities.update_all(last_activity_at: 6.minutes.ago)

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      ObserverNotificationJob.perform_now("Account", @account.id)
      ObserverNotificationJob.perform_now("Account", @account.id)
    end

    assert_equal 1, @provider.templates.size
    assert_equal "Hay actividad en 2 conversaciones.", @provider.templates.first.dig(:variables, "1")
    assert_equal "https://ayla.test/conversations?filter=unread", @provider.templates.first.dig(:variables, "2")
    assert_equal 8, @account.conversation_observer_activities.sum(:unread_activity_count)
  end

  test "notification failure preserves activity and records the error" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Hay estacionamiento?")
    @account.conversation_observer_activities.update_all(last_activity_at: 6.minutes.ago)

    result = Whatsapp::ObserverNotifier.call(actor: Whatsapp::HostActor.owner(@account), provider: FailingProvider.new)

    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    assert message.persisted?
    assert_not result.sent?
    assert_nil activity.observer_notified_at
    assert_equal "Twilio observer delivery failed", activity.last_notification_error
  end

  test "active operational workflow postpones observer without changing it" do
    session = @account.owner_whatsapp_sessions.create!(
      participant_phone: @account.owner_whatsapp_number,
      actor_role: "owner",
      state: "viewing_item",
      active_category: "pedidos",
      active_item_type: "OwnerTask",
      active_item_id: 123,
      started_at: Time.current,
      expires_at: 30.minutes.from_now
    )
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Nueva actividad")
    @account.conversation_observer_activities.update_all(last_activity_at: 6.minutes.ago)
    clear_enqueued_jobs

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      ObserverNotificationJob.perform_now("Account", @account.id)
    end

    assert_empty @provider.templates
    assert_equal 123, session.reload.active_item_id
    assert_enqueued_jobs 1, only: ObserverNotificationJob
  end

  test "observer activity never blocks an operational notification" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Necesito una manta")
    @conversation.owner_tasks.create!(
      account: @account,
      property: @property,
      guest: @guest,
      message: message,
      kind: "request",
      guest_phone: @guest.phone_number,
      property_name: @property.display_name,
      category: "extra_item",
      title: "Pedido",
      description: message.body,
      source_channel: "whatsapp"
    )

    result = Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    assert result.sent?
    assert @account.owner_whatsapp_sessions.active.exists?
  end

  test "co-host records activity only for assigned properties" do
    co_host = @account.co_hosts.create!(name: "María", whatsapp_number: "+59899001002", observer_mode_enabled: true)
    @property.update!(co_host: co_host)
    other_property = @account.properties.create!(name: "Owner only")
    other_guest = @account.guests.create!(property: other_property, phone_number: "+59899002003")
    other_conversation = other_guest.conversations.create!(property: other_property)

    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Permitida")
    other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "No permitida")

    assert_equal [@conversation.id], co_host.conversation_observer_activities.pluck(:conversation_id)
  end

  test "disabling clears pending activity and reactivation ignores historical activity" do
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Antes")
    @account.update!(observer_mode_enabled: false)

    assert_empty @account.conversation_observer_activities.unseen
    assert_no_enqueued_jobs only: ObserverNotificationJob do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Desactivado")
    end

    @account.update!(observer_mode_enabled: true)
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Después")

    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    assert_equal 1, activity.unread_activity_count
    assert_nil activity.observer_seen_at
  end
end
