require "test_helper"

class WhatsappOwnerNotificationQueueTest < ActiveSupport::TestCase
  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :sent_messages

    def initialize
      @sent_messages = []
    end

    def send_message(to:, body:, media_urls: [])
      @sent_messages << { to: to, body: body }
      super
    end

    def send_template(to:, template_sid:, variables: {})
      @sent_messages << { to: to, template_sid: template_sid, variables: variables }
      super
    end
  end

  setup do
    @original_notice_sid = ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
    ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"] = "HX_NOTICE"
    @account = Account.create!(name: "Queue owner", owner_whatsapp_number: "+15559991000", owner_whatsapp_escalations_enabled: true)
    @property = @account.properties.create!(name: "Queue apartment")
    @guest = @account.guests.create!(phone_number: "+15550001000", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    @provider = RecordingProvider.new
  end

  teardown do
    ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"] = @original_notice_sid
  end

  test "uses notice content SID and sends owner-scoped counters once" do
    create_task("request", "Dos mantas")
    create_task("inquiry", "Cómo se usa el horno")
    create_alert("El aire no prende")

    first = Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    second = Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    assert first.sent?
    assert_not second.sent?
    assert_equal "owner_session_active", second.error
    assert_equal 1, @provider.sent_messages.count { |message| message[:template_sid] }
    assert_equal({ "1" => "1", "2" => "1", "3" => "1" }, @provider.sent_messages.first[:variables])
    assert_equal "HX_NOTICE", @provider.sent_messages.first[:template_sid]
  end

  test "does not mix pending counters or sessions between owners" do
    create_task("request", "Solo owner uno")
    other = Account.create!(name: "Other owner", owner_whatsapp_number: "+15559992000", owner_whatsapp_escalations_enabled: true)
    other_property = other.properties.create!(name: "Other apartment")
    other_guest = other.guests.create!(phone_number: "+15550002000", property: other_property)
    other_conversation = other_guest.conversations.create!(property: other_property)
    message = other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Solo owner dos")
    other_conversation.owner_tasks.create!(account: other, property: other_property, guest: other_guest, message: message, kind: "inquiry",
      guest_phone: other_guest.phone_number, property_name: other_property.display_name, category: "other", title: "Consulta",
      description: message.body, status: "open", source_channel: "whatsapp")

    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    Whatsapp::OwnerEscalationNotifier.call(account: other, provider: @provider)

    templates = @provider.sent_messages.select { |message_data| message_data[:template_sid] }
    assert_equal({ "1" => "1", "2" => "0", "3" => "0" }, templates[0][:variables])
    assert_equal({ "1" => "0", "2" => "1", "3" => "0" }, templates[1][:variables])
    assert_equal 1, @account.owner_whatsapp_sessions.active.count
    assert_equal 1, other.owner_whatsapp_sessions.active.count
  end

  test "only one active session can exist for an owner" do
    create_task("request", "Pendiente")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    assert_raises(ActiveRecord::RecordNotUnique) do
      @account.owner_whatsapp_sessions.create!(state: "menu", started_at: Time.current, expires_at: 30.minutes.from_now)
    end
  end

  test "new pending events do not replace the active item and are announced once after exit" do
    first = create_task("inquiry", "Primera consulta")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("consultas", "SM1")
    session = @account.owner_whatsapp_sessions.active.first
    assert_equal first.id, session.active_item_id

    create_task("request", "Pedido nuevo")
    create_alert("Alerta nueva")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    assert_equal first.id, session.reload.active_item_id
    templates_before_exit = @provider.sent_messages.count { |message| message[:template_sid] }

    inbound("salir", "SM2")
    assert_equal templates_before_exit + 1, @provider.sent_messages.count { |message| message[:template_sid] }
  end

  test "owner reply is sent exactly to the session active item and duplicate webhook is ignored" do
    first = create_task("request", "Primero")
    second = create_task("request", "Último")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("pedidos", "SM10")
    session = @account.owner_whatsapp_sessions.active.first
    assert_equal first.id, session.active_item_id

    inbound("Texto EXACTO, sin traducir.", "SM11")
    inbound("Texto EXACTO, sin traducir.", "SM11")

    assert_equal "resolved", first.reload.status
    assert_equal "open", second.reload.status
    assert_equal ["Texto EXACTO, sin traducir."], @conversation.messages.where(sender: "owner").pluck(:body)
    assert_equal 1, @provider.sent_messages.count { |message| message[:to] == @guest.phone_number && message[:body] == "Texto EXACTO, sin traducir." }
  end

  test "remember creates approved property FAQ and no_recordar does not" do
    inquiry = create_task("inquiry", "¿Cómo enciendo el horno?")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("consultas", "SM20")
    inbound("Girando la perilla roja.", "SM21")
    assert_equal "awaiting_learning_confirmation", @account.owner_whatsapp_sessions.active.first.state
    inbound("recordar", "SM22")

    faq = @property.faqs.find_by!(question: inquiry.current_guest_message)
    assert_equal "approved", faq.status
    assert faq.active?
    assert_equal "Girando la perilla roja.", faq.answer

    second = create_task("inquiry", "¿Dónde está la escoba?")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("consultas", "SM23")
    inbound("En el placard.", "SM24")
    inbound("no_recordar", "SM25")
    assert_nil @property.faqs.find_by(question: second.current_guest_message)
  end

  private

  def create_task(kind, body)
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: body)
    @conversation.owner_tasks.create!(account: @account, property: @property, guest: @guest, message: message, kind: kind,
      guest_phone: @guest.phone_number, property_name: @property.display_name, category: "other", title: body,
      description: body, status: "open", source_channel: "whatsapp")
  end

  def create_alert(body)
    @conversation.alerts.create!(property: @property, guest: @guest, alert_type: "maintenance_issue", title: body, description: body)
  end

  def inbound(body, sid)
    Whatsapp::IncomingMessageHandler.new({ "From" => "whatsapp:#{@account.owner_whatsapp_number}", "To" => "whatsapp:+15550009999",
                                           "Body" => body, "MessageSid" => sid }, provider: @provider).call
  end
end
