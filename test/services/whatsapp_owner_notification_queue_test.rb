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

    def send_interactive(to:, content_key:, variables: {}, fallback_body:)
      @sent_messages << { to: to, content_key: content_key, variables: variables, fallback_body: fallback_body, interactive: true }
      super
    end
  end

  class FailingInteractiveProvider < RecordingProvider
    def send_interactive(to:, content_key:, variables: {}, fallback_body:)
      super
      false
    end
  end

  class CheckoutTemplateProvider < RecordingProvider
    def template_supports_action?(_template_sid, action_id)
      action_id == "checkouts"
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

  test "checkout-aware notice sends four owner-scoped counters while the old template remains at three" do
    create_checkout("Ya dejamos las llaves y nos fuimos")
    other = Account.create!(name: "Checkout other", owner_whatsapp_number: "+15559993000", owner_whatsapp_escalations_enabled: true)
    other_property = other.properties.create!(name: "Other checkout apartment")
    other_guest = other.guests.create!(phone_number: "+15550003000", property: other_property)
    other_conversation = other_guest.conversations.create!(property: other_property)
    other_message = other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Ya nos fuimos")
    other.checkout_events.create!(property: other_property, guest: other_guest, conversation: other_conversation,
      source_message: other_message, reservation_key: "conversation:#{other_conversation.id}",
      guest_message_body: other_message.body, checked_out_at: Time.current)

    old_provider = RecordingProvider.new
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: old_provider)
    assert_equal({ "1" => "0", "2" => "0", "3" => "0" }, old_provider.sent_messages.first[:variables])

    @account.owner_whatsapp_sessions.active.first.update!(state: "resolved", resolved_at: Time.current)
    new_provider = CheckoutTemplateProvider.new
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: new_provider)
    assert_equal({ "1" => "0", "2" => "0", "3" => "0", "4" => "1" }, new_provider.sent_messages.first[:variables])
    assert_equal 1, @account.checkout_events.pending.count
    assert_equal 1, other.checkout_events.pending.count
  end

  test "owner reviews scoped checkouts without reply or learning actions and marks one seen" do
    event = create_checkout("Ya dejamos el departamento y las llaves quedaron en la caja")
    @provider = CheckoutTemplateProvider.new
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Checkouts", "SM-CO-1", action_id: "checkouts")

    session = @account.owner_whatsapp_sessions.active.first
    assert_equal "CheckoutEvent", session.active_item_type
    assert_equal event.id, session.active_item_id
    detail = @provider.sent_messages.find { |message| message[:body]&.include?("Caso #CO-#{event.id}") }.fetch(:body)
    assert_includes detail, @property.display_name
    assert_includes detail, @guest.phone_number
    assert_includes detail, event.guest_message_body
    assert_includes detail, "Salida informada:"

    actions = @provider.sent_messages.reverse.find { |message| message[:content_key] == :checkout_actions }
    assert_equal "Opciones: checkout_visto, siguiente o salir.", actions[:fallback_body]
    assert_not_includes actions[:fallback_body], "responder"
    assert_not_includes actions[:fallback_body], "recordar"

    inbound("Marcar como visto", "SM-CO-2", action_id: "checkout_visto")
    assert_equal "seen", event.reload.status
    assert event.owner_seen_at.present?
  end

  test "a new checkout stays queued and never replaces another active item" do
    task = create_task("request", "Necesito una manta")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM-CO-QUEUE-1", action_id: "pedidos")
    session = @account.owner_whatsapp_sessions.active.first

    create_checkout("Ya nos fuimos")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    assert_equal "OwnerTask", session.reload.active_item_type
    assert_equal task.id, session.active_item_id
    assert_equal 1, @account.checkout_events.pending.count
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

    inbound("Responder", "SM10A", action_id: "responder")
    inbound("Texto EXACTO, sin traducir.", "SM11")
    assert_equal "open", first.reload.status
    assert_equal "Texto EXACTO, sin traducir.", session.reload.draft_reply_body
    assert_empty @conversation.messages.where(sender: "owner")

    inbound("Enviar", "SM12", action_id: "enviar")
    inbound("Enviar", "SM12", action_id: "enviar")

    assert_equal "resolved", first.reload.status
    assert_equal "open", second.reload.status
    assert_equal ["Texto EXACTO, sin traducir."], @conversation.messages.where(sender: "owner").pluck(:body)
    assert_equal 1, @provider.sent_messages.count { |message| message[:to] == @guest.phone_number && message[:body] == "Texto EXACTO, sin traducir." }
  end

  test "remember creates approved property FAQ and no_recordar does not" do
    inquiry = create_task("inquiry", "¿Cómo enciendo el horno?")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("consultas", "SM20")
    inbound("Responder", "SM20A", action_id: "responder")
    inbound("Girando la perilla roja.", "SM21")
    inbound("Enviar", "SM21A", action_id: "enviar")
    learning_session = @account.owner_whatsapp_sessions.active.first
    assert_equal "awaiting_learning_confirmation", learning_session.state
    assert_nil learning_session.active_item_type
    assert_nil learning_session.active_item_id
    assert_nil learning_session.draft_reply_body
    inbound("Sí, recordar", "SM22", action_id: "recordar")

    faq = @property.faqs.find_by!(question: inquiry.current_guest_message)
    assert_equal "approved", faq.status
    assert faq.active?
    assert_equal "Girando la perilla roja.", faq.answer

    second = create_task("inquiry", "¿Dónde está la escoba?")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("consultas", "SM23")
    inbound("Responder", "SM23A", action_id: "responder")
    inbound("En el placard.", "SM24")
    inbound("Enviar", "SM24A", action_id: "enviar")
    inbound("No recordar", "SM25", action_id: "no_recordar")
    assert_nil @property.faqs.find_by(question: second.current_guest_message)
  end

  test "sending resolves the case clears its context and reaches no more pending" do
    task = create_task("request", "Necesito una almohada")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM-LIFECYCLE-1", action_id: "pedidos")
    inbound("Responder", "SM-LIFECYCLE-2", action_id: "responder")
    inbound("La dejamos en la puerta.", "SM-LIFECYCLE-3")
    inbound("Enviar", "SM-LIFECYCLE-4", action_id: "enviar")

    session = @account.owner_whatsapp_sessions.order(:created_at).last
    assert_equal "resolved", task.reload.status
    assert_equal "responded", task.response_delivery_state
    assert_equal "resolved", session.reload.state
    assert_nil session.active_item_type
    assert_nil session.active_item_id
    assert_nil session.draft_reply_body
    assert_equal 0, @account.owner_tasks.open.count
    assert @provider.sent_messages.any? { |message| message[:body] == "No hay más pendientes en pedidos." }
  end

  test "next recalculates from the database when the previous case was resolved elsewhere" do
    first = create_task("request", "Primer caso")
    second = create_task("request", "Segundo caso")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM-STALE-1", action_id: "pedidos")
    session = @account.owner_whatsapp_sessions.active.first
    assert_equal first.id, session.active_item_id

    first.update!(status: "resolved", response_delivery_state: "responded", final_response_body: "Resuelto externamente")
    inbound("Siguiente", "SM-STALE-2", action_id: "siguiente")

    assert_equal "viewing_item", session.reload.state
    assert_equal second.id, session.active_item_id
    assert_equal "open", second.reload.status
  end

  test "a resolved case never appears again while cycling through remaining pending cases" do
    first = create_task("request", "Primero")
    second = create_task("request", "Segundo")
    third = create_task("request", "Tercero")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM-NOREPEAT-1", action_id: "pedidos")
    inbound("Responder", "SM-NOREPEAT-2", action_id: "responder")
    inbound("Resuelto.", "SM-NOREPEAT-3")
    inbound("Enviar", "SM-NOREPEAT-4", action_id: "enviar")

    session = @account.owner_whatsapp_sessions.active.first
    assert_equal second.id, session.active_item_id
    inbound("Siguiente", "SM-NOREPEAT-5", action_id: "siguiente")
    assert_equal third.id, session.reload.active_item_id
    inbound("Siguiente", "SM-NOREPEAT-6", action_id: "siguiente")

    assert_equal second.id, session.reload.active_item_id
    assert_equal "resolved", first.reload.status
    assert_not_equal first.id, session.active_item_id
    assert_equal [second.id, third.id], @account.owner_tasks.open.order(:created_at).pluck(:id)
  end

  test "item view includes original request clarifications recent conversation and last guest message" do
    task = create_task("inquiry", "La puerta del balcón está trabada")
    clarification = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Seguí las instrucciones pero todavía no abre")
    @conversation.messages.create!(sender: "ai", channel: "whatsapp", body: "Probá levantando completamente la manija.")
    last_guest = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Todavía sigue trabada")
    task.update!(metadata: { "updates" => [{ "message_id" => clarification.id, "body" => clarification.body }] })

    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Consultas", "SM30", action_id: "consultas")

    detail = @provider.sent_messages.reverse.find { |message| message[:body]&.include?("Caso #C-#{task.id}") }[:body]
    assert_includes detail, "Solicitud original:"
    assert_includes detail, "La puerta del balcón está trabada"
    assert_includes detail, "Aclaraciones:"
    assert_includes detail, clarification.body
    assert_includes detail, "Conversación reciente:"
    assert_includes detail, "Ayla:"
    assert_includes detail, "Último mensaje del huésped:"
    assert_includes detail, last_guest.body
  end

  test "item context never includes messages from another property or conversation" do
    task = create_task("inquiry", "Consulta de esta propiedad")
    other_property = @account.properties.create!(name: "Private apartment")
    other_guest = @account.guests.create!(phone_number: "+15550009999", property: other_property)
    other_conversation = other_guest.conversations.create!(property: other_property)
    other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "MENSAJE PRIVADO DE OTRA CONVERSACION")

    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Consultas", "SM35", action_id: "consultas")

    detail = @provider.sent_messages.reverse.find { |message| message[:body]&.include?("Caso #C-#{task.id}") }[:body]
    assert_includes detail, "Consulta de esta propiedad"
    assert_not_includes detail, "MENSAJE PRIVADO DE OTRA CONVERSACION"
    assert_not_includes detail, "Private apartment"
  end

  test "free text and typo while viewing do not navigate or reach the guest" do
    task = create_task("request", "Necesito toallas")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM40", action_id: "pedidos")
    session = @account.owner_whatsapp_sessions.active.first

    inbound("Siguitne", "SM41")

    assert_equal "viewing_item", session.reload.state
    assert_equal task.id, session.active_item_id
    assert_equal "open", task.reload.status
    assert_empty @conversation.messages.where(sender: "owner")
    assert_includes @provider.sent_messages[-2][:body], "Elegí una de las opciones"
  end

  test "edit replaces the draft and cancel returns to the same item without sending" do
    task = create_task("request", "Necesito una manta")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM50", action_id: "pedidos")
    inbound("Responder", "SM51", action_id: "responder")
    inbound("Primer borrador", "SM52")
    inbound("Editar", "SM53", action_id: "editar")
    inbound("Segundo borrador", "SM54")

    session = @account.owner_whatsapp_sessions.active.first
    assert_equal "Segundo borrador", session.draft_reply_body
    inbound("Cancelar", "SM55", action_id: "cancelar")

    assert_equal "viewing_item", session.reload.state
    assert_nil session.draft_reply_body
    assert_equal task.id, session.active_item_id
    assert_equal "open", task.reload.status
    assert_empty @conversation.messages.where(sender: "owner")
  end

  test "next omit and exit work through interactive action ids" do
    first = create_task("request", "Primero")
    second = create_task("request", "Segundo")
    third = create_task("request", "Tercero")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM56", action_id: "pedidos")
    session = @account.owner_whatsapp_sessions.active.first
    assert_equal first.id, session.active_item_id

    inbound("Siguiente", "SM57", action_id: "siguiente")
    assert_equal second.id, session.reload.active_item_id
    assert_equal "open", first.reload.status

    inbound("Omitir", "SM58", action_id: "omitir")
    assert_equal third.id, session.reload.active_item_id
    assert_equal "open", second.reload.status

    inbound("Salir", "SM59", action_id: "salir")
    assert_equal "resolved", session.reload.state
    assert_equal "open", third.reload.status
    assert_nil session.draft_reply_body
  end

  test "new pending does not change the active item or draft" do
    first = create_task("request", "Primero")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM60", action_id: "pedidos")
    inbound("Responder", "SM61", action_id: "responder")
    inbound("Mi borrador", "SM62")
    session = @account.owner_whatsapp_sessions.active.first

    create_task("request", "Nuevo pendiente")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    assert_equal first.id, session.reload.active_item_id
    assert_equal "Mi borrador", session.draft_reply_body
    assert_equal "awaiting_send_confirmation", session.state
  end

  test "expired session confirmation never sends to the guest" do
    task = create_task("request", "Pedido")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM70", action_id: "pedidos")
    inbound("Responder", "SM71", action_id: "responder")
    inbound("No debe enviarse", "SM72")
    session = @account.owner_whatsapp_sessions.active.first
    session.update!(expires_at: 1.minute.ago)

    inbound("Enviar", "SM73", action_id: "enviar")

    assert_equal "open", task.reload.status
    assert_empty @conversation.messages.where(sender: "owner")
    assert_not_equal session.id, @account.owner_whatsapp_sessions.active.first&.id
  end

  test "interactive content failure keeps the confirmation draft and active item safe" do
    @provider = FailingInteractiveProvider.new
    task = create_task("request", "Pedido")
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)
    inbound("Pedidos", "SM80", action_id: "pedidos")
    inbound("Responder", "SM81", action_id: "responder")
    inbound("Borrador seguro", "SM82")

    session = @account.owner_whatsapp_sessions.active.first
    assert_equal "awaiting_send_confirmation", session.state
    assert_equal task.id, session.active_item_id
    assert_equal "Borrador seguro", session.draft_reply_body
    assert_equal "open", task.reload.status
    assert_empty @conversation.messages.where(sender: "owner")
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

  def create_checkout(body)
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: body)
    @account.checkout_events.create!(property: @property, guest: @guest, conversation: @conversation,
      source_message: message, provider_message_sid: "SM-EVENT-#{message.id}", reservation_key: "conversation:#{@conversation.id}", guest_message_body: body,
      checked_out_at: message.created_at)
  end

  def inbound(body, sid, action_id: nil)
    Whatsapp::IncomingMessageHandler.new({ "From" => "whatsapp:#{@account.owner_whatsapp_number}", "To" => "whatsapp:+15550009999",
                                           "Body" => body, "MessageSid" => sid, "ButtonPayload" => action_id }, provider: @provider).call
  end
end
