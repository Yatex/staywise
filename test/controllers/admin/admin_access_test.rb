require "test_helper"

class AdminAccessTest < ActionDispatch::IntegrationTest
  setup do
    @admin_account = Account.create!(name: "Admin Account")
    @admin_account.subscriptions.create!(plan: "business", status: "active")
    @admin = @admin_account.users.create!(
      name: "Admin User",
      email: "admin-test@staywise.test",
      role: "admin",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )

    @owner_account = Account.create!(name: "Owner Account")
    @owner_account.subscriptions.create!(plan: "starter", status: "trialing", trial_ends_at: 14.days.from_now)
    @owner = @owner_account.users.create!(
      name: "Owner User",
      email: "owner-test@staywise.test",
      role: "owner",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @owner_account.properties.create!(name: "Owner Apartment")
  end

  test "normal users cannot access admin sections" do
    sign_in_as(@owner)

    get admin_users_path

    assert_redirected_to dashboard_path

    get admin_errors_path

    assert_redirected_to dashboard_path

    get admin_ai_traces_path

    assert_redirected_to dashboard_path

    get admin_ai_settings_path

    assert_redirected_to dashboard_path
  end

  test "admins can access users stats and errors sections" do
    sign_in_as(@admin)

    get admin_users_path
    assert_response :success
    assert_includes response.body, "Starter"
    assert_includes response.body, @owner_account.active_subscription.trial_ends_on.to_fs(:long)
    assert_select "[data-controller='sidebar']", count: 1
    assert_select "button[data-action='sidebar#toggle'][aria-expanded='true']", count: 1
    assert_select "aside a[title='Propiedades'][aria-label='Propiedades']", count: 1

    get admin_stats_path
    assert_response :success
    assert_includes response.body, "Planes pagos activos"

    get admin_errors_path
    assert_response :success

    get admin_ai_traces_path
    assert_response :success
    assert_includes response.body, "AI Trace"

    get admin_ai_settings_path
    assert_response :success
    assert_includes response.body, "Configuración IA"
  end

  test "admin index only lists own conversations but direct show can inspect another account without replying" do
    admin_property = @admin_account.properties.create!(name: "Admin Apartment")
    admin_guest = @admin_account.guests.create!(phone_number: "+59899000001", property: admin_property)
    admin_conversation = admin_guest.conversations.create!(property: admin_property)
    admin_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje de la cuenta admin")

    guest = @owner_account.guests.create!(phone_number: "+59899112233", property: @property)
    conversation = guest.conversations.create!(property: @property)
    conversation.messages.create!(
      sender: "guest",
      channel: "whatsapp",
      body: "No funciona la cerradura"
    )
    conversation.messages.create!(
      sender: "ai",
      channel: "whatsapp",
      body: "Estoy revisando el problema."
    )

    sign_in_as(@admin)

    get conversations_path
    assert_response :success
    assert_includes response.body, "59899000001"
    assert_select "a[href='#{conversation_path(admin_conversation)}']", count: 1
    assert_not_includes response.body, "59899112233"
    assert_select "a[href='#{conversation_path(conversation)}']", count: 0

    get conversation_path(conversation)
    assert_response :success
    assert_includes response.body, "No funciona la cerradura"
    assert_includes response.body, "Estoy revisando el problema."
    assert_not_includes response.body, "Responder al huésped"
    assert_select "form[action='#{reply_conversation_path(conversation)}']", count: 0
  end

  test "admin index only lists own properties but direct show can inspect another account without editing" do
    admin_property = @admin_account.properties.create!(name: "Admin Apartment")
    @property.update!(
      address: "Calle Diagnóstico 123",
      wifi_name: "Owner WiFi",
      wifi_password: "owner-secret-password",
      access_instructions: "Código privado 7788",
      parking_instructions: "Estacionamiento visible para diagnóstico.",
      tags: ["diagnostico"]
    )
    @property.sensitive_data.create!(kind: "door_code", value: "9911", active: true)
    @property.knowledge_blocks.create!(
      title: "Aire acondicionado",
      category: "appliances",
      content: "Instrucciones visibles para diagnóstico.",
      status: "active"
    )
    @property.faqs.create!(
      question: "¿Cómo ingreso?",
      answer: "Usá el código informado.",
      category: "building_access",
      active: true,
      status: "approved",
      source_type: "manual"
    )

    sign_in_as(@admin)

    get properties_path
    assert_response :success
    assert_includes response.body, "Admin Apartment"
    assert_select "a[href='#{property_path(admin_property)}']", count: 1
    assert_not_includes response.body, "Owner Apartment"
    assert_select "a[href='#{property_path(@property)}']", count: 0
    assert_select "form[action='#{co_host_property_path(@property)}']", count: 0

    get property_path(@property)
    assert_response :success
    assert_includes response.body, "Vista administrativa · Owner Account"
    assert_includes response.body, "Aire acondicionado"
    assert_includes response.body, "¿Cómo ingreso?"
    assert_includes response.body, "Estacionamiento visible para diagnóstico."
    assert_includes response.body, "Owner WiFi"
    assert_includes response.body, "owner-secret-password"
    assert_includes response.body, "Código privado 7788"
    assert_includes response.body, "9911"
    assert_not_includes response.body, "Editar propiedad"
    assert_not_includes response.body, "Eliminar propiedad"
    assert_not_includes response.body, "Agregar FAQ"
    assert_not_includes response.body, "Editar configuración"

    get whatsapp_qr_property_path(@property, format: :svg)
    assert_response :success
  end

  test "normal user cannot directly inspect another account property or conversation" do
    admin_property = @admin_account.properties.create!(name: "Private Admin Apartment")
    admin_guest = @admin_account.guests.create!(phone_number: "+59899000002", property: admin_property)
    admin_conversation = admin_guest.conversations.create!(property: admin_property)

    sign_in_as(@owner)

    get property_path(admin_property)
    assert_response :not_found

    get conversation_path(admin_conversation)
    assert_response :not_found
  end

  test "admin can update ai decision score settings" do
    sign_in_as(@admin)

    patch admin_ai_settings_path, params: {
      account: {
        ai_high_score_threshold: 82,
        ai_medium_score_threshold: 45,
        ai_safety_score_threshold: 88,
        ai_max_clarification_attempts: 3
      }
    }

    assert_redirected_to admin_ai_settings_path
    @admin_account.reload
    assert_equal 82, @admin_account.ai_high_score_threshold
    assert_equal 45, @admin_account.ai_medium_score_threshold
    assert_equal 88, @admin_account.ai_safety_score_threshold
    assert_equal 3, @admin_account.ai_max_clarification_attempts
  end

  test "admin ai settings shows rejected evaluated cases with scores" do
    property = @admin_account.properties.create!(name: "Admin Apartment")
    guest = @admin_account.guests.create!(phone_number: "+15550004444", property: property)
    conversation = guest.conversations.create!(property: property)
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "hay internet?")
    AIDecisionLog.create!(
      account: @admin_account,
      property: property,
      guest: guest,
      conversation: conversation,
      message: message,
      original_message: message,
      route: "remote_ai_rejected",
      decision: "escalate",
      final_outcome: "escalate",
      language: "es",
      validator_result: "rejected",
      rejection_reason: "invalid_evidence:property.not_real",
      detected_intents: [{ "type" => "wifi", "status" => "answered" }],
      evidence_ids: ["property.wifi_name"],
      ai_response_payload: {
        "outcome" => "reply",
        "message_body" => "Sí, hay Wi-Fi.",
        "audit" => {
          "grounded_decision_builder" => {
            "decision_scores" => {
              "answer_confidence" => 93,
              "evidence_relevance_score" => 100,
              "safety_score" => 90
            },
            "score_thresholds" => {
              "high_score_threshold" => 75,
              "medium_score_threshold" => 40,
              "safety_score_threshold" => 75
            }
          }
        }
      },
      validation_results: {
        "status" => "rejected",
        "passed" => false,
        "reasons" => ["invalid_evidence:property.not_real"]
      },
      fallback_reason: "validation_rejected",
      payload: {
        "rejected_candidate" => {
          "outcome" => "reply",
          "response_text" => "Sí, hay Wi-Fi.",
          "confidence" => 0.93,
          "evidence_ids" => ["property.wifi_name"]
        },
        "final_response_text" => "Gracias por tu mensaje. Lo estoy consultando con el anfitrión y te responderé en breve."
      }
    )

    sign_in_as(@admin)

    get admin_ai_settings_path

    assert_response :success
    assert_includes response.body, "Últimos casos evaluados"
    assert_includes response.body, "hay internet?"
    assert_includes response.body, "Sí, hay Wi-Fi."
    assert_includes response.body, "invalid_evidence:property.not_real"
    assert_includes response.body, "93"
    assert_includes response.body, "100"
    assert_includes response.body, "Fallback"
  end

  test "admin can inspect sanitized ai decision trace" do
    guest = @owner_account.guests.create!(phone_number: "+15550003333", property: @property)
    conversation = guest.conversations.create!(property: @property)
    message = conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "a que hora es el check in?")
    trace = AIDecisionLog.create!(
      account: @owner_account,
      property: @property,
      guest: guest,
      conversation: conversation,
      message: message,
      original_message: message,
      route: "remote_ai_accepted_with_warnings",
      decision: "reply",
      final_outcome: "reply",
      language: "es",
      validator_result: "accepted_with_warnings",
      detected_intents: [{ "type" => "check_in", "status" => "answered" }],
      evidence_ids: ["property.check_in_time"],
      ai_request_payload: AIDecisionLog.sanitize_trace({ "Authorization" => "Bearer secret-token", "body" => "a que hora es el check in?" }),
      ai_response_payload: {
        "response_text" => "El check-in es a las 15:00.",
        "safe_fallback_response" => "No tengo esa información confirmada. Necesito revisarla antes de responderte."
      },
      tool_calls: [
        {
          "tool_name" => "stay_facts",
          "timestamp" => Time.current.iso8601,
          "input" => { "requested_fields" => ["check_in_time"] },
          "context" => {
            "conversation_id" => conversation.id,
            "reservation_id" => "RES-44",
            "property_id" => @property.id,
            "property_name" => @property.display_name,
            "account_id" => @owner_account.id,
            "account_name" => @owner_account.name,
            "decision_context_fingerprint" => "sha256:1234567890abcdef"
          },
          "request" => { "requested_fields" => ["check_in_time"] },
          "response" => [{
            "evidence_id" => "property.check_in_time",
            "type" => "property_fact",
            "title" => "check_in_time",
            "content" => "15:00"
          }],
          "output_summary" => { "check_in_time" => "15:00", "wifi_password" => "SuperSecret123" },
          "evidence_returned" => [{
            "evidence_id" => "property.check_in_time",
            "type" => "property_fact",
            "title" => "Horario de check-in",
            "content" => "15:00",
            "property_id" => @property.id,
            "property_name" => @property.display_name,
            "account_id" => @owner_account.id,
            "account_name" => @owner_account.name,
            "scope" => "property",
            "referenced" => true,
            "validation_passed" => true,
            "validation_label" => "Property matches conversation",
            "validation" => {
              "authorized" => true,
              "valid" => true,
              "provenance_reason" => "property_match"
            }
          }],
          "evidence_referenced" => [{
            "evidence_id" => "property.check_in_time"
          }],
          "latency_ms" => 42
        }
      ].then { |value| AIDecisionLog.sanitize_trace(value) },
      validation_results: {
        "status" => "accepted_with_warnings",
        "passed" => true,
        "warnings" => ["evidence_reference_not_resolved"],
        "evidence" => [{
          "evidence_id" => "property.check_in_time",
          "authorized" => true,
          "scope" => "property",
          "conversation_property_id" => @property.id,
          "evidence_property_id" => @property.id,
          "conversation_account_id" => @owner_account.id,
          "evidence_account_id" => @owner_account.id
        }]
      },
      provider_delivery_status: "sent",
      payload: AIDecisionLog.sanitize_trace(
        {
          "checkin_trace" => {
            "label" => "CHECKIN_TRACE",
            "detected_language" => "es",
            "detected_intents" => [{ "type" => "check_in" }],
            "guest_context_called" => true,
            "stay_facts_called" => true,
            "check_in_evidence_found" => true,
            "evidence_id" => "property.check_in_time",
            "validation_passed" => true,
            "final_response_or_fallback" => "El check-in es a las 15:00."
          },
          "evidence_trace" => [
            {
              "evidence_id" => "property.check_in_time",
              "source" => "property",
              "scope" => "property",
              "authorized" => true,
              "conversation_property_id" => @property.id,
              "evidence_property_id" => @property.id,
              "conversation_account_id" => @owner_account.id,
              "evidence_account_id" => @owner_account.id
            }
          ],
          "original_decision" => {
            "action" => "reply",
            "outcome" => "reply",
            "response_text" => "El check-in es a las 15:00."
          },
          "conversation_property_id" => @property.id,
          "conversation_account_id" => @owner_account.id,
          "alert" => { "created" => false },
          "whatsapp_delivery" => { "sent" => true, "delivery_status" => "sent" },
          "safe_fallback_response" => "No tengo esa información confirmada. Necesito revisarla antes de responderte.",
          "final_response_text" => "El check-in es a las 15:00.",
          "rails_fallback_source" => "respuesta principal",
          "fallback_language" => "es"
        }
      )
    )

    sign_in_as(@admin)

    get admin_ai_traces_path(decision: "reply", tool: "stay_facts")
    assert_response :success
    assert_includes response.body, "a que hora es el check in?"
    assert_select "a[href^='#{admin_ai_trace_path(trace)}'] p", text: "a que hora es el check in?", count: 1
    assert_select "a[href^='#{admin_ai_trace_path(trace)}'] span", text: "reply", count: 1
    assert_includes response.body, "stay_facts"

    get admin_ai_trace_path(trace)
    assert_response :success
    assert_select "a[href='#{conversation_path(conversation)}']", text: "Ver conversación", count: 1
    assert_select "a[href='#{property_path(@property)}']", text: "Ver propiedad", count: 1
    assert_includes response.body, "CHECKIN_TRACE"
    assert_includes response.body, "Fallback seguro del AI"
    assert_includes response.body, "No tengo esa información confirmada"
    assert_includes response.body, "Respuesta final de Rails"
    assert_includes response.body, "Decisión original de la AI"
    assert_includes response.body, "Procedencia Rails"
    assert_includes response.body, "Advertencias no bloqueantes"
    assert_includes response.body, "evidence_reference_not_resolved"
    assert_includes response.body, "Tool Requests"
    assert_includes response.body, "Contexto resuelto por Rails"
    assert_includes response.body, "Decision Context ID"
    assert_includes response.body, "sha256:1234567890abcdef"
    assert_includes response.body, "Request de la AI"
    assert_includes response.body, "Tool Response"
    assert_includes response.body, "Evidence returned · 1"
    assert_includes response.body, "Evidence referenced · 1"
    assert_includes response.body, "Contenido completo recibido por la AI"
    assert_includes response.body, "Property matches conversation"
    assert_includes response.body, "Owner Apartment"
    assert_includes response.body, "autorizada: true"
    assert_includes response.body, "conversación: #{@property.id}"
    assert_includes response.body, "evidencia: #{@property.id}"
    assert_includes response.body, "property.check_in_time"
    assert_includes response.body, "[REDACTED]"
    assert_not_includes response.body, "SuperSecret123"
    assert_not_includes response.body, "secret-token"
  end

  test "AI trace index paginates metadata without selecting heavy payload columns" do
    26.times do |index|
      AIDecisionLog.create!(
        account: @owner_account,
        property: @property,
        route: "remote_ai",
        decision: "paged_trace",
        final_outcome: "reply",
        tool_calls: [{ tool_name: "property_brain", response: { content: "HEAVY-#{index}" } }],
        evidence_ids: ["faq.#{index}"],
        payload: { prompt: "HEAVY-PROMPT-#{index}" },
        ai_request_payload: { conversation_history: ["HEAVY-HISTORY-#{index}"] },
        ai_response_payload: { output: "HEAVY-OUTPUT-#{index}" }
      )
    end
    sign_in_as(@admin)
    select_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      select_sql << sql if sql.match?(/SELECT.+FROM "ai_decision_logs"/m) && sql.include?("LIMIT")
    end

    get admin_ai_traces_path(decision: "paged_trace", property_id: @property.id)

    assert_response :success
    assert_equal 25, response.body.scan(/Trace #\d+/).uniq.size
    assert_select "a", text: "Siguiente", count: 1 do |links|
      assert_includes links.first["href"], "decision=paged_trace"
      assert_includes links.first["href"], "property_id=#{@property.id}"
    end
    metadata_query = select_sql.find { |sql| sql.include?("jsonb_array_elements") }
    assert metadata_query
    %w[payload ai_request_payload ai_response_payload tool_calls].each do |column|
      refute_match(/"ai_decision_logs"\."#{column}"/, metadata_query)
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "admin can inspect and resolve operational errors" do
    error = OperationalError.create!(
      account: @owner_account,
      property: @property,
      source: "whatsapp_webhook",
      severity: "critical",
      error_class: "RuntimeError",
      message: "Webhook failed",
      context: { "from" => "whatsapp:+15550000001" }
    )

    sign_in_as(@admin)

    get admin_error_path(error)
    assert_response :success
    assert_includes response.body, "Webhook failed"

    patch resolve_admin_error_path(error)
    assert_redirected_to admin_errors_path
    assert error.reload.resolved?
  end

  test "admin can extend an account subscription" do
    sign_in_as(@admin)

    post extend_subscription_admin_user_path(@owner), params: {
      plan: "pro",
      end_date: 45.days.from_now.to_date
    }

    assert_redirected_to admin_users_path
    subscription = @owner_account.active_subscription.reload
    assert_equal "pro", subscription.plan
    assert_equal "active", subscription.status
    assert subscription.current_period_end > 40.days.from_now
  end

  test "admin can create edit and remove a property limit override without changing stripe subscription" do
    subscription = @owner_account.active_subscription
    subscription.update!(
      plan: "business",
      status: "active",
      stripe_customer_id: "cus_admin_override",
      stripe_subscription_id: "sub_admin_override"
    )
    sign_in_as(@admin)

    patch update_property_limit_admin_user_path(@owner), params: { property_limit_override: "35" }
    assert_redirected_to admin_users_path
    assert_equal 35, @owner_account.reload.property_limit_override

    patch update_property_limit_admin_user_path(@owner), params: { property_limit_override: "25" }
    assert_equal 25, @owner_account.reload.property_limit_override

    patch update_property_limit_admin_user_path(@owner), params: { property_limit_override: "" }
    assert_nil @owner_account.reload.property_limit_override

    subscription.reload
    assert_equal "business", subscription.plan
    assert_equal "active", subscription.status
    assert_equal "cus_admin_override", subscription.stripe_customer_id
    assert_equal "sub_admin_override", subscription.stripe_subscription_id
    assert_nil subscription.current_period_end
  end

  test "normal user cannot update a property limit override" do
    sign_in_as(@owner)

    patch update_property_limit_admin_user_path(@owner), params: { property_limit_override: "35" }

    assert_redirected_to dashboard_path
    assert_nil @owner_account.reload.property_limit_override
  end

  test "admin users page shows a compact plan and property limit editor" do
    @owner_account.active_subscription.update!(plan: "business", status: "active")
    @owner_account.update!(property_limit_override: 35)
    sign_in_as(@admin)

    get admin_users_path

    assert_response :success
    assert_includes response.body, "Business"
    assert_includes response.body, "Límite especial"
    assert_includes response.body, "Propiedades"
    assert_includes response.body, "Huéspedes"
    assert_includes response.body, "Conversaciones"
    assert_not_includes response.body, ">Cuenta<"
    assert_select "input[name='property_limit_override'][value='35']"
    assert_not_includes response.body, "Vacío usa el límite del plan"
  end

  test "admin rejects non-integer and negative overrides" do
    sign_in_as(@admin)

    patch update_property_limit_admin_user_path(@owner), params: { property_limit_override: "3.5" }
    assert_nil @owner_account.reload.property_limit_override

    patch update_property_limit_admin_user_path(@owner), params: { property_limit_override: "-1" }
    assert_nil @owner_account.reload.property_limit_override
  end

  test "admin can update another user's role" do
    sign_in_as(@admin)

    patch update_role_admin_user_path(@owner), params: { role: "member" }

    assert_redirected_to admin_users_path
    assert_equal "member", @owner.reload.role
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
