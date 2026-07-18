require "test_helper"

class ObserverActivityRecorderTest < ActiveSupport::TestCase
  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :templates

    def initialize
      @templates = []
    end

    def send_template(to:, template_sid:, variables: {})
      @templates << { to: to, template_sid: template_sid, variables: variables }
      true
    end
  end

  class FailingProvider < Whatsapp::Providers::NullProvider
    def send_template(to:, template_sid:, variables: {})
      DeliveryResult.new(success?: false, error: "Twilio observer delivery failed")
    end
  end

  setup do
    @previous_sid = ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = "HX_OBSERVER"
    @account = Account.create!(name: "Observer account", owner_whatsapp_number: "+59899001001", observer_mode_enabled: true)
    @property = @account.properties.create!(name: "Observer apartment")
    @guest = @account.guests.create!(property: @property, phone_number: "+59899002001", name: "Juan")
    @conversation = @guest.conversations.create!(property: @property)
    @provider = RecordingProvider.new
  end

  teardown do
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = @previous_sid
  end

  test "observer mode is disabled by default" do
    account = Account.create!(name: "Observer disabled")
    co_host = account.co_hosts.create!(name: "Co-host", whatsapp_number: "+59899003001")

    assert_not account.observer_mode_enabled?
    assert_not co_host.observer_mode_enabled?
  end

  test "disabled observer mode does not record or notify activity" do
    @account.update!(observer_mode_enabled: false)

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje sin observador")
    end

    assert_empty @account.conversation_observer_activities
    assert_empty @provider.templates
  end

  test "guest and ai messages update one recipient activity" do
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Cómo entro?")
      @conversation.messages.create!(sender: "ai", channel: "whatsapp", body: "Usá el código indicado.")
    end

    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    assert_equal 2, activity.unread_activity_count
    assert_equal "ai", activity.latest_message_direction
    assert_nil activity.observer_seen_at
    assert_equal 1, @provider.templates.size
  end

  test "owner response through ayla updates observable activity" do
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "owner", channel: "dashboard", body: "Te ayudo desde Ayla.")
    end

    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    assert_equal "owner", activity.latest_message_direction
    assert_equal 1, activity.unread_activity_count
  end

  test "media-only guest message registers activity without calling ai" do
    AI::DecisionService.stub(:call, ->(*) { raise "AI must not be called for media-only activity" }) do
      Whatsapp::ProviderFactory.stub(:build, @provider) do
        result = Whatsapp::IncomingMessageHandler.new(
          {
            "From" => "whatsapp:+59899002009",
            "To" => "whatsapp:+59899999999",
            "Body" => "",
            "PropertyToken" => @property.public_token,
            "NumMedia" => "1",
            "MediaUrl0" => "https://example.test/photo.jpg",
            "MediaContentType0" => "image/jpeg"
          },
          provider: @provider
        ).call

        assert_nil result[:decision]
        assert_equal "Archivo multimedia recibido.", result[:message].body
        assert_equal "guest", @account.conversation_observer_activities.find_by!(conversation: result[:conversation]).latest_message_direction
      end
    end
  end

  test "relevant conversation status change updates observable activity" do
    Observer::ActivityRecorder.stub(:call, ->(**options) {
      assert_equal @conversation, options[:conversation]
      assert_equal "system", options[:direction]
    }) do
      @conversation.update!(status: "closed")
    end
  end

  test "ten nearby messages in one conversation send one template" do
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      10.times { |index| @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje #{index}") }
    end

    assert_equal 1, @provider.templates.size
    assert_equal "HX_OBSERVER", @provider.templates.first[:template_sid]
    assert_equal({ "1" => "1" }, @provider.templates.first[:variables])
    assert_equal 10, @account.conversation_observer_activities.find_by!(conversation: @conversation).unread_activity_count
  end

  test "two conversations count as two conversations rather than messages" do
    other_guest = @account.guests.create!(property: @property, phone_number: "+59899002002", name: "Ana")
    other_conversation = other_guest.conversations.create!(property: @property)

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      3.times { |index| @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Primera #{index}") }
      2.times { |index| other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Segunda #{index}") }
    end
    @account.conversation_observer_activities.update_all(observer_notified_at: 6.minutes.ago)

    result = Whatsapp::ObserverNotifier.call(actor: Whatsapp::HostActor.owner(@account), provider: @provider)

    assert result.sent?
    assert_equal 2, result.pending_conversations
    assert_equal({ "1" => "2" }, @provider.templates.last[:variables])
  end

  test "notification failure preserves the guest message and records the recipient error" do
    message = nil

    assert_nothing_raised do
      Whatsapp::ProviderFactory.stub(:build, FailingProvider.new) do
        message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Hay estacionamiento?")
      end
    end

    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    assert message.persisted?
    assert_equal "¿Hay estacionamiento?", message.reload.body
    assert_nil activity.observer_notified_at
    assert_equal "Twilio observer delivery failed", activity.last_notification_error
  end

  test "active operational session accumulates activity without changing active item" do
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

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Nueva actividad")
    end

    assert_empty @provider.templates
    assert_equal 123, session.reload.active_item_id
    assert_equal 1, @account.conversation_observer_activities.unseen.count
  end

  test "recent observer notice prevents an immediate operational template" do
    Whatsapp::ProviderFactory.stub(:build, @provider) do
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
    end

    result = Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    assert_not result.sent?
    assert_equal "observer_notice_recent", result.error
    assert_equal 1, @provider.templates.size
  end

  test "co-host receives activity only for assigned properties" do
    co_host = @account.co_hosts.create!(
      name: "María",
      whatsapp_number: "+59899001002",
      observer_mode_enabled: true
    )
    @property.update!(co_host: co_host)
    other_property = @account.properties.create!(name: "Owner only")
    other_guest = @account.guests.create!(property: other_property, phone_number: "+59899002003")
    other_conversation = other_guest.conversations.create!(property: other_property)

    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Permitida")
      other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "No permitida")
    end

    assert_equal [@conversation.id], co_host.conversation_observer_activities.pluck(:conversation_id)
  end

  test "disabling stops notifications and reactivation ignores historical pending activity" do
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Antes")
    end
    @account.update!(observer_mode_enabled: false)
    assert_empty @account.conversation_observer_activities.unseen

    templates_before = @provider.templates.size
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Desactivado")
    end
    assert_equal templates_before, @provider.templates.size

    @account.update!(observer_mode_enabled: true)
    @account.conversation_observer_activities.update_all(observer_notified_at: 6.minutes.ago)
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Después")
    end
    assert_equal templates_before + 1, @provider.templates.size
    assert_equal 1, @account.conversation_observer_activities.find_by!(conversation: @conversation).unread_activity_count
  end
end
