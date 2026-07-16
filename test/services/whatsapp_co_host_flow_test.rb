require "test_helper"

class WhatsappCoHostFlowTest < ActiveSupport::TestCase
  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :messages

    def initialize(fail_phone: nil)
      @messages = []
      @fail_phone = fail_phone
      @mutex = Mutex.new
    end

    def send_message(to:, body:, media_urls: [])
      @mutex.synchronize { @messages << { type: :message, to: to, body: body } }
      to == @fail_phone ? false : true
    end

    def send_template(to:, template_sid:, variables: {})
      @mutex.synchronize { @messages << { type: :template, to: to, variables: variables } }
      to == @fail_phone ? false : true
    end

    def send_interactive(to:, content_key:, variables: {}, fallback_body:)
      @mutex.synchronize { @messages << { type: :interactive, to: to, content_key: content_key, body: fallback_body } }
      to == @fail_phone ? false : true
    end
  end

  setup do
    @original_sid = ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
    ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"] = "HX_NOTICE"
    @account = Account.create!(name: "Co-host flow", owner_whatsapp_number: "+59899100001", owner_whatsapp_escalations_enabled: true)
    @property = @account.properties.create!(name: "Allowed property")
    @other_property = @account.properties.create!(name: "Owner only property")
    @co_host = @account.co_hosts.create!(name: "Maria", whatsapp_number: "+59899100002")
    @property.update!(co_host: @co_host)
    @guest = @account.guests.create!(phone_number: "+59899100003", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    @other_guest = @account.guests.create!(phone_number: "+59899100004", property: @other_property)
    @other_conversation = @other_guest.conversations.create!(property: @other_property)
    @provider = RecordingProvider.new
  end

  teardown do
    ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"] = @original_sid
  end

  test "notifies owner and co-host with independently scoped counters" do
    allowed = create_task(@conversation, "request", "Allowed request")
    create_task(@other_conversation, "inquiry", "Owner-only inquiry")

    Whatsapp::OwnerEscalationNotifier.call(item: allowed, provider: @provider)

    owner_notice = @provider.messages.find { |message| message[:type] == :template && message[:to] == @account.owner_whatsapp_number }
    co_host_notice = @provider.messages.find { |message| message[:type] == :template && message[:to] == @co_host.whatsapp_number }
    assert_equal({ "1" => "1", "2" => "1", "3" => "0" }, owner_notice[:variables])
    assert_equal({ "1" => "1", "2" => "0", "3" => "0" }, co_host_notice[:variables])
    assert_equal 2, @account.owner_whatsapp_sessions.active.count
  end

  test "co-host delivery failure does not block owner and removal stops future notifications" do
    provider = RecordingProvider.new(fail_phone: @co_host.whatsapp_number)
    task = create_task(@conversation, "request", "Request")
    result = Whatsapp::OwnerEscalationNotifier.call(item: task, provider: provider)

    assert result.sent?
    assert provider.messages.any? { |message| message[:to] == @account.owner_whatsapp_number }
    assert provider.messages.any? { |message| message[:to] == @co_host.whatsapp_number }

    @account.owner_whatsapp_sessions.update_all(state: "resolved", resolved_at: Time.current)
    @property.update!(co_host: nil)
    another = create_task(@conversation, "request", "Another request")
    provider.messages.clear
    Whatsapp::OwnerEscalationNotifier.call(item: another, provider: provider)
    assert_not provider.messages.any? { |message| message[:to] == @co_host.whatsapp_number }
  end

  test "owner delivery failure still notifies co-host without mixing scoped counters" do
    provider = RecordingProvider.new(fail_phone: @account.owner_whatsapp_number)
    allowed = create_task(@conversation, "request", "Allowed request")
    create_task(@other_conversation, "inquiry", "Owner-only inquiry")

    Whatsapp::OwnerEscalationNotifier.call(item: allowed, provider: provider)

    owner_notice = provider.messages.find { |message| message[:type] == :template && message[:to] == @account.owner_whatsapp_number }
    co_host_notice = provider.messages.find { |message| message[:type] == :template && message[:to] == @co_host.whatsapp_number }
    assert_equal({ "1" => "1", "2" => "1", "3" => "0" }, owner_notice[:variables])
    assert_equal({ "1" => "1", "2" => "0", "3" => "0" }, co_host_notice[:variables])
    assert_equal "queued", @account.owner_whatsapp_sessions.find_by!(participant_phone: @account.owner_whatsapp_number).state
    assert @account.owner_whatsapp_sessions.active.exists?(participant_phone: @co_host.whatsapp_number)
  end

  test "corrupt matching phones are deduplicated before notification" do
    @co_host.update_column(:whatsapp_number, @account.owner_whatsapp_number)
    task = create_task(@conversation, "request", "One notice")

    Whatsapp::OwnerEscalationNotifier.call(item: task, provider: @provider)

    assert_equal 1, @provider.messages.count { |message| message[:type] == :template && message[:to] == @account.owner_whatsapp_number }
  end

  test "co-host sees only assigned property items in every category" do
    allowed_task = create_task(@conversation, "request", "Allowed")
    create_task(@other_conversation, "request", "Forbidden")
    allowed_alert = @conversation.alerts.create!(property: @property, guest: @guest, alert_type: "maintenance_issue", title: "Allowed alert")
    @other_conversation.alerts.create!(property: @other_property, guest: @other_guest, alert_type: "maintenance_issue", title: "Forbidden alert")

    Whatsapp::OwnerEscalationNotifier.call(item: allowed_task, provider: @provider)
    inbound(@co_host.whatsapp_number, "Pedidos", "SM-COHOST-1", "pedidos")
    session = @account.owner_whatsapp_sessions.active.find_by!(participant_phone: @co_host.whatsapp_number)
    assert_equal allowed_task.id, session.active_item_id
    inbound(@co_host.whatsapp_number, "Salir", "SM-COHOST-2", "salir")

    @account.owner_whatsapp_sessions.where(participant_phone: @co_host.whatsapp_number).update_all(state: "resolved", resolved_at: Time.current)
    Whatsapp::OwnerEscalationNotifier.call(item: allowed_alert, provider: @provider)
    inbound(@co_host.whatsapp_number, "Alertas", "SM-COHOST-3", "alertas")
    assert_equal allowed_alert.id, @account.owner_whatsapp_sessions.active.find_by!(participant_phone: @co_host.whatsapp_number).active_item_id
  end

  test "first confirmed reply wins and only the winner gets inquiry learning" do
    task = create_task(@conversation, "inquiry", "Question")
    Whatsapp::OwnerEscalationNotifier.call(item: task, provider: @provider)
    prepare_draft(@account.owner_whatsapp_number, "Owner answer", "OWNER")
    prepare_draft(@co_host.whatsapp_number, "Co-host answer", "COHOST")

    inbound(@co_host.whatsapp_number, "Enviar", "SM-WIN", "enviar")
    inbound(@account.owner_whatsapp_number, "Enviar", "SM-LOSE", "enviar")

    assert_equal "responded", task.reload.response_delivery_state
    assert_equal "Co-host answer", task.final_response_body
    assert_equal "co_host", task.resolved_by_role
    assert_equal 1, @provider.messages.count { |message| message[:to] == @guest.phone_number }
    co_host_session = @account.owner_whatsapp_sessions.active.find_by(participant_phone: @co_host.whatsapp_number)
    assert_equal "awaiting_learning_confirmation", co_host_session&.state
    owner_texts = @provider.messages.select { |message| message[:to] == @account.owner_whatsapp_number }.map { |message| message[:body] }.compact
    assert owner_texts.any? { |body| body.include?("ya fue respondido") }
  end

  test "owner can win the same race and duplicate webhook delivery stays idempotent" do
    task = create_task(@conversation, "inquiry", "Another question")
    Whatsapp::OwnerEscalationNotifier.call(item: task, provider: @provider)
    prepare_draft(@account.owner_whatsapp_number, "Owner wins", "OWNER-FIRST")
    prepare_draft(@co_host.whatsapp_number, "Co-host loses", "COHOST-SECOND")

    inbound(@account.owner_whatsapp_number, "Enviar", "SM-OWNER-WIN", "enviar")
    inbound(@account.owner_whatsapp_number, "Enviar", "SM-OWNER-WIN", "enviar")
    inbound(@co_host.whatsapp_number, "Enviar", "SM-COHOST-LOSE", "enviar")

    assert_equal "responded", task.reload.response_delivery_state
    assert_equal "Owner wins", task.final_response_body
    assert_equal "owner", task.resolved_by_role
    assert_equal 1, @provider.messages.count { |message| message[:to] == @guest.phone_number }
    owner_session = @account.owner_whatsapp_sessions.active.find_by(participant_phone: @account.owner_whatsapp_number)
    assert_equal "awaiting_learning_confirmation", owner_session&.state
  end

  test "co-host reviews checkouts only for assigned properties" do
    allowed = create_checkout(@conversation, "We left the keys")
    create_checkout(@other_conversation, "Owner-only checkout")
    Whatsapp::OwnerEscalationNotifier.call(item: allowed, provider: @provider)

    inbound(@co_host.whatsapp_number, "Checkouts", "SM-COHOST-CHECKOUT-1", "checkouts")
    session = @account.owner_whatsapp_sessions.active.find_by!(participant_phone: @co_host.whatsapp_number)
    assert_equal "CheckoutEvent", session.active_item_type
    assert_equal allowed.id, session.active_item_id

    inbound(@co_host.whatsapp_number, "Marcar como visto", "SM-COHOST-CHECKOUT-2", "checkout_visto")
    assert_equal "seen", allowed.reload.status
    assert @other_property.checkout_events.pending.exists?
  end

  test "alert reply is shared and only one host can resolve it" do
    alert = @conversation.alerts.create!(property: @property, guest: @guest, alert_type: "maintenance_issue", title: "No hot water")
    Whatsapp::OwnerEscalationNotifier.call(item: alert, provider: @provider)
    prepare_draft(@account.owner_whatsapp_number, "Owner alert answer", "OWNER-ALERT", "alertas")
    prepare_draft(@co_host.whatsapp_number, "Co-host alert answer", "COHOST-ALERT", "alertas")

    inbound(@co_host.whatsapp_number, "Enviar", "SM-ALERT-WIN", "enviar")
    inbound(@account.owner_whatsapp_number, "Enviar", "SM-ALERT-LOSE", "enviar")

    assert_equal "responded", alert.reload.response_delivery_state
    assert_equal "Co-host alert answer", alert.final_response_body
    assert_equal "co_host", alert.resolved_by_role
    assert_equal 1, @provider.messages.count { |message| message[:to] == @guest.phone_number }
  end

  test "a removed co-host cannot send a prepared reply" do
    task = create_task(@conversation, "request", "Request")
    Whatsapp::OwnerEscalationNotifier.call(item: task, provider: @provider)
    prepare_draft(@co_host.whatsapp_number, "Exact answer", "DUP")
    @property.update!(co_host: nil)

    inbound(@co_host.whatsapp_number, "Enviar", "SM-DUP", "enviar")
    assert_equal "open", task.reload.status
    assert_not @provider.messages.any? { |message| message[:to] == @guest.phone_number }
  end

  private

  def create_task(conversation, kind, body)
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: body)
    conversation.owner_tasks.create!(account: @account, property: conversation.property, guest: conversation.guest, message: message,
      kind: kind, guest_phone: conversation.guest.phone_number, property_name: conversation.property.display_name,
      category: "other", title: body, description: body, status: "open", source_channel: "whatsapp")
  end

  def create_checkout(conversation, body)
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: body)
    @account.checkout_events.create!(property: conversation.property, guest: conversation.guest, conversation: conversation,
      source_message: message, provider_message_sid: "SM-CHECKOUT-#{message.id}", reservation_key: "conversation:#{conversation.id}",
      guest_message_body: body, checked_out_at: message.created_at)
  end

  def inbound(phone, body, sid, action_id = nil)
    Whatsapp::IncomingMessageHandler.new({ "From" => "whatsapp:#{phone}", "To" => "whatsapp:+59899999999",
      "Body" => body, "MessageSid" => sid, "ButtonPayload" => action_id }, provider: @provider).call
  end

  def prepare_draft(phone, body, prefix, category = "consultas")
    inbound(phone, category.capitalize, "SM-#{prefix}-1", category)
    inbound(phone, "Responder", "SM-#{prefix}-2", "responder")
    inbound(phone, body, "SM-#{prefix}-3")
  end
end
