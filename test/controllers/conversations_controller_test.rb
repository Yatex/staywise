require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  class SuccessfulProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:)
      DeliveryResult.new(success?: true, provider_message_id: "SM_owner_reply", provider_status: "queued")
    end
  end

  class FailingProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:)
      false
    end
  end

  setup do
    @account = Account.create!(name: "Conversation Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Conversation Owner",
      email: "conversation-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Conversation Apartment")
    @guest = @account.guests.create!(phone_number: "+15550002000", property: @property)
    @conversation = @guest.conversations.create!(property: @property, status: "escalated")
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Puedo hacer late checkout?")

    sign_in_as(@user)
  end

  test "owner can reply to guest through ayla whatsapp number" do
    Whatsapp::ProviderFactory.stub(:build, SuccessfulProvider.new) do
      assert_difference -> { @conversation.messages.where(sender: "owner").count }, 1 do
        post reply_conversation_path(@conversation), params: {
          reply: {
            body: "Hola, podemos coordinar late checkout hasta las 12:00."
          }
        }
      end
    end

    owner_message = @conversation.messages.where(sender: "owner").last

    assert_redirected_to conversation_path(@conversation, anchor: "message-#{owner_message.id}")
    assert_equal "whatsapp", owner_message.channel
    assert_equal "Hola, podemos coordinar late checkout hasta las 12:00.", owner_message.body
    assert_equal @user.id, owner_message.metadata["sent_by_user_id"]
    assert_equal "ayla_dashboard", owner_message.metadata["sent_via"]
    assert_equal "SM_owner_reply", owner_message.metadata["provider_message_id"]
    assert_equal "queued", owner_message.metadata["delivery_status"]
  end

  test "show page marks conversation panels for automatic refresh" do
    get conversation_path(@conversation)

    assert_response :success
    assert_select "[data-controller='conversation-refresh']"
    assert_select "[data-conversation-refresh-target='messages']"
    assert_select "[data-conversation-refresh-target='alerts']"
    assert_select "[data-conversation-refresh-target='guestRequests']"
    assert_select "[data-conversation-refresh-target='status']"
  end

  test "direct conversation link returns to the conversation after login" do
    delete logout_path
    get conversation_path(@conversation)

    assert_redirected_to login_path

    post login_path, params: { email: @user.email, password: "password123" }

    assert_redirected_to conversation_path(@conversation)
  end

  test "observer indicators filter unread activity and opening marks only the owner activity seen" do
    @account.update!(observer_mode_enabled: true, owner_whatsapp_number: "+59899220001")
    @conversation.messages.create!(sender: "ai", channel: "whatsapp", body: "Respuesta observable")
    activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)

    get conversations_path(filter: "unread")
    assert_response :success
    assert_includes response.body, "Con novedades"
    assert_includes response.body, "Nueva actividad"
    assert_includes response.body, "Ayla respondió"

    get conversation_path(@conversation)
    assert_response :success
    assert activity.reload.observer_seen_at.present?
    assert_equal 0, activity.unread_activity_count

    get conversations_path(filter: "unread")
    assert_not_includes response.body, "15550002000"
  end

  test "index omits escalation tags and renders relative times in spanish" do
    @conversation.messages.create!(
      sender: "ai",
      channel: "whatsapp",
      body: "Respuesta anterior",
      created_at: 2.days.ago
    )

    get conversations_path

    assert_response :success
    assert_not_includes response.body, "Escalado"
    assert_not_includes response.body, "Translation missing"
    assert_includes response.body, "Ayla respondió 2 días atrás"
  end

  test "refresh endpoint renders only live conversation fragments" do
    get refresh_conversation_path(@conversation)

    assert_response :success
    assert_select "[data-conversation-refresh-target='messages']"
    assert_select "[data-conversation-refresh-target='alerts']"
    assert_select "[data-conversation-refresh-target='guestRequests']"
    assert_select "[data-conversation-refresh-target='status']"
    assert_not_includes @response.body, "Responder al huésped"
  end

  test "show page uses phone number as chat title and property as tag" do
    get conversation_path(@conversation)

    assert_response :success
    assert_includes @response.body, "15550002000"
    assert_not_includes @response.body, "+15550002000"
    assert_not_includes @response.body, "Huésped de WhatsApp"
    assert_select "span", text: "Conversation Apartment"
  end

  test "show page renders complete message history and delivery failures" do
    system_message = @conversation.messages.create!(
      sender: "system",
      channel: "whatsapp",
      body: "👋 Hola, soy Ayla, tu asistente.\n\n🇪🇸 Escribí en español.\n🇬🇧 Write in English.\n🇧🇷 Escreva em português.",
      metadata: { delivery_status: "sent" }
    )
    ai_message = @conversation.messages.create!(
      sender: "ai",
      channel: "whatsapp",
      body: "Estoy revisando tu consulta.",
      metadata: { delivery_status: "failed", delivery_error: "twilio_error" }
    )
    owner_message = @conversation.messages.create!(
      sender: "owner",
      channel: "whatsapp",
      body: "Podés salir a las 12:00.",
      metadata: { delivery_status: "queued" }
    )

    get conversation_path(@conversation)

    assert_response :success
    [@conversation.messages.first, system_message, ai_message, owner_message].each do |message|
      assert_select "#message-#{message.id}", count: 1
      assert_includes @response.body, message.body
    end
    assert_includes @response.body, "Falló el envío por WhatsApp"
    assert_includes @response.body, "Aceptado por Twilio"
  end

  test "show page includes real guest inbound and ai outbound messages from whatsapp flow" do
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      AI::DecisionResult.from_hash(
        decision: "reply",
        language: "es",
        message_body: "La respuesta está en la FAQ de la propiedad.",
        intent_summary: "faq",
        detected_intents: [{ type: "faq", status: "answered" }],
        evidence_ids: ["faq.123"],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: false, reason_code: nil, summary_for_host: nil },
        missing_information: [],
        safety_flags: [],
        confidence: 0.93
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550003000",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Cómo bajo a la pileta?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    conversation = result.fetch(:conversation)

    get conversation_path(conversation)

    assert_response :success
    assert_select "#message-#{result.fetch(:message).id}", count: 1
    assert_select "#message-#{conversation.messages.where(sender: "ai").last.id}", count: 1
    assert_includes @response.body, "¿Cómo bajo a la pileta?"
    assert_includes @response.body, "La respuesta está en la FAQ de la propiedad."
  end

  test "show page includes related guest requests in side panel and message marker" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "quiero un vino")
    @conversation.guest_requests.create!(
      account: @account,
      property: @property,
      guest: @guest,
      message: message,
      guest_phone: @guest.phone_number,
      property_name: @property.display_name,
      property_address: @property.address,
      category: "food_or_drink",
      title: "Pedido de comida o bebida",
      description: "quiero un vino",
      ai_summary: "El huésped pidió un vino.",
      status: "open",
      priority: "normal",
      source_channel: "whatsapp"
    )

    get conversation_path(@conversation)

    assert_response :success
    assert_select "[data-conversation-refresh-target='guestRequests']"
    assert_includes @response.body, "Pedidos de la conversación"
    assert_includes @response.body, "Pedido de comida o bebida"
    assert_includes @response.body, "Pedido creado"
  end

  test "refresh endpoint includes guest requests fragment" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "necesito una cama extra")
    @conversation.guest_requests.create!(
      account: @account,
      property: @property,
      guest: @guest,
      message: message,
      guest_phone: @guest.phone_number,
      property_name: @property.display_name,
      category: "extra_bed",
      title: "Pedido de cama extra",
      description: "necesito una cama extra",
      status: "open",
      priority: "normal",
      source_channel: "whatsapp"
    )

    get refresh_conversation_path(@conversation)

    assert_response :success
    assert_select "[data-conversation-refresh-target='guestRequests']"
    assert_includes @response.body, "Pedido de cama extra"
  end

  test "show page includes guest escalation and owner manual reply from whatsapp flow" do
    result = nil

    AI::DecisionService.stub(:call, ->(conversation:, guest_message:) {
      AI::DecisionResult.from_hash(
        decision: "escalate",
        language: "es",
        message_body: "No tengo esa información confirmada. La consulto con el anfitrión y te aviso.",
        intent_summary: "unknown",
        detected_intents: [{ type: "unknown_question", status: "escalated" }],
        evidence_ids: [],
        required_capabilities: [],
        proposed_action: nil,
        escalation: { required: true, reason_code: "unknown_question", summary_for_host: "El huésped hizo una pregunta sin información disponible." },
        missing_information: ["unknown_question"],
        safety_flags: [],
        confidence: 0.72,
        owner_task_kind: "inquiry"
      )
    }) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+15550003001",
          "To" => "whatsapp:+15550009999",
          "Body" => "#{@property.whatsapp_reference} ¿Puedo invitar visitas a la pileta?"
        },
        provider: Whatsapp::Providers::NullProvider.new
      ).call
    end

    conversation = result.fetch(:conversation)
    assert_nil result.fetch(:alert)
    assert_equal "inquiry", result.fetch(:guest_request).kind

    Whatsapp::ProviderFactory.stub(:build, SuccessfulProvider.new) do
      post reply_conversation_path(conversation), params: {
        reply: {
          body: "No se pueden invitar visitas a la pileta."
        }
      }
    end

    get conversation_path(conversation)

    assert_response :success
    assert_select "#message-#{result.fetch(:message).id}", count: 1
    assert_select "#message-#{conversation.messages.where(sender: "ai").last.id}", count: 1
    assert_select "#message-#{conversation.messages.where(sender: "owner").last.id}", count: 1
    assert_includes @response.body, "¿Puedo invitar visitas a la pileta?"
    assert_includes @response.body, "No tengo esa información confirmada"
    assert_includes @response.body, "No se pueden invitar visitas a la pileta."

    assert_nil result.fetch(:alert)
  end

  test "show page includes guest messages referenced by ai trace logs" do
    legacy_guest = @account.guests.create!(phone_number: "+15550002001", property: @property)
    legacy_conversation = legacy_guest.conversations.create!(property: @property, status: "active")
    traced_message = legacy_conversation.messages.create!(
      sender: "guest",
      channel: "whatsapp",
      body: "a que hora es el check in?"
    )
    AIDecisionLog.create!(
      account: @account,
      property: @property,
      guest: legacy_guest,
      conversation: @conversation,
      message: traced_message,
      original_message: traced_message,
      route: "remote_ai",
      decision: "escalate",
      final_outcome: "escalate",
      language: "es",
      fallback_reason: "legacy_trace_message_mismatch",
      payload: { "whatsapp_delivery" => { "delivery_status" => "not_sent" } }
    )

    get conversation_path(@conversation)

    assert_response :success
    assert_select "#message-#{traced_message.id}", count: 1
    assert_includes @response.body, "a que hora es el check in?"
  end

  test "owners only see messages for their tenant after conversation is relinked to another property" do
    other_account = Account.create!(name: "Other Owner Stays")
    other_account.subscriptions.create!(plan: "growth", status: "trialing")
    other_user = other_account.users.create!(
      name: "Other Owner",
      email: "other-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    other_property = other_account.properties.create!(name: "Other Property")

    shared_phone = "+15550009901"
    old_guest = @account.guests.create!(phone_number: shared_phone, property: @property)
    old_conversation = old_guest.conversations.create!(property: @property, channel: "whatsapp", status: "active")
    old_message = old_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje del owner anterior")

    other_guest = other_account.guests.create!(phone_number: shared_phone, property: other_property)
    old_conversation.update!(guest: other_guest, property: other_property)
    new_message = old_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje del nuevo owner")

    get conversation_path(old_conversation)
    assert_response :success
    assert_select "#message-#{old_message.id}", count: 1
    assert_select "#message-#{new_message.id}", count: 0
    assert_includes @response.body, "Conversation Apartment"
    assert_not_includes @response.body, "Other Property"

    delete logout_path
    sign_in_as(other_user)

    get conversation_path(old_conversation)
    assert_response :success
    assert_select "#message-#{old_message.id}", count: 0
    assert_select "#message-#{new_message.id}", count: 1
    assert_includes @response.body, "Other Property"
    assert_not_includes @response.body, "Mensaje del owner anterior"
  end

  test "ai trace panel is not rendered on conversation show and remains available in admin" do
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "a que hora es el check in?")
    AIDecisionLog.create!(
      account: @account,
      property: @property,
      guest: @guest,
      conversation: @conversation,
      message: message,
      original_message: message,
      route: "remote_ai",
      decision: "ask_clarifying_question",
      final_outcome: "ask_clarifying_question",
      language: "es",
      detected_intents: [{ "type" => "ambiguous_time", "status" => "needs_clarification" }],
      payload: {
        "checkin_trace" => {
          "label" => "CHECKIN_TRACE",
          "guest_context_called" => true,
          "stay_facts_called" => true
        },
        "whatsapp_delivery" => { "delivery_status" => "sent" }
      }
    )

    get conversation_path(@conversation)
    assert_response :success
    assert_not_includes @response.body, "AI Trace"
    assert_not_includes @response.body, "CHECKIN_TRACE disponible"
    assert_not_includes @response.body, "Ver trazas filtradas"

    delete logout_path
    admin = @account.users.create!(
      name: "Internal Admin",
      email: "conversation-admin@staywise.test",
      role: "admin",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    sign_in_as(admin)

    get conversation_path(@conversation)
    assert_response :success
    assert_not_includes @response.body, "CHECKIN_TRACE disponible"
    assert_not_includes @response.body, "Ver trazas filtradas"

    get admin_ai_traces_path(conversation_id: @conversation.id)
    assert_response :success
    assert_includes @response.body, "AI Trace"
    assert_includes @response.body, "a que hora es el check in?"
  end

  test "null whatsapp provider does not store owner reply as sent" do
    assert_no_difference -> { @conversation.messages.count } do
      post reply_conversation_path(@conversation), params: {
        reply: {
          body: "Esto no debería guardarse como enviado."
        }
      }
    end

    assert_redirected_to conversation_path(@conversation)
    assert_equal "WhatsApp no está conectado. Configurá Twilio antes de responder desde Ayla.", flash[:alert]
  end

  test "blank owner reply is rejected" do
    assert_no_difference -> { @conversation.messages.count } do
      post reply_conversation_path(@conversation), params: {
        reply: {
          body: "   "
        }
      }
    end

    assert_redirected_to conversation_path(@conversation)
    assert_equal "Escribí un mensaje para enviar.", flash[:alert]
  end

  test "failed whatsapp delivery stores owner message as failed" do
    Whatsapp::ProviderFactory.stub(:build, FailingProvider.new) do
      assert_difference -> { @conversation.messages.where(sender: "owner").count }, 1 do
        post reply_conversation_path(@conversation), params: {
          reply: {
            body: "Intento de respuesta."
          }
        }
      end
    end

    failed_message = @conversation.messages.where(sender: "owner").last

    assert_redirected_to conversation_path(@conversation, anchor: "message-#{failed_message.id}")
    assert_equal "No se pudo enviar el mensaje por WhatsApp. Revisá la configuración del proveedor.", flash[:alert]
    assert_equal "Intento de respuesta.", failed_message.body
    assert_equal "failed", failed_message.metadata["delivery_status"]
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
