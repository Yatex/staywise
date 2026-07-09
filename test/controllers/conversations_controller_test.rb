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
    assert_select "[data-conversation-refresh-target='status']"
  end

  test "refresh endpoint renders only live conversation fragments" do
    get refresh_conversation_path(@conversation)

    assert_response :success
    assert_select "[data-conversation-refresh-target='messages']"
    assert_select "[data-conversation-refresh-target='alerts']"
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
      body: "Ya vinculé este chat con Conversation Apartment.",
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
        confidence: 0.72
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
    assert_equal "open", result.fetch(:alert).status

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

    suggestion = @property.faqs.last
    assert_equal "pending_review", suggestion.status
    assert_not suggestion.active?
    assert_equal "owner_answer", suggestion.source_type
    assert_equal result.fetch(:alert), suggestion.source_alert
  end

  test "show page includes guest messages referenced by ai trace logs" do
    legacy_conversation = @guest.conversations.create!(property: @property, status: "active")
    traced_message = legacy_conversation.messages.create!(
      sender: "guest",
      channel: "whatsapp",
      body: "a que hora es el check in?"
    )
    AIDecisionLog.create!(
      account: @account,
      property: @property,
      guest: @guest,
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
