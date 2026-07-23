require "test_helper"

class AIFinalContractTest < ActiveSupport::TestCase
  class MediaProvider < Whatsapp::Providers::BaseProvider
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def send_message(to:, body:, media_urls: [])
      @deliveries << { to: to, body: body, media_urls: media_urls }
      DeliveryResult.new(success?: true, provider_message_id: "SM-final-contract", provider_status: "queued")
    end
  end

  setup do
    @account = Account.create!(name: "Final Contract", owner_whatsapp_number: "+59899000111")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @property = @account.properties.create!(name: "Ayla Home", wifi_name: "Pepe", owner_contact_phone: "+59899000222")
    @guest = @account.guests.create!(phone_number: "+59899000333", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
  end

  test "reply confidence and unresolved evidence are decided by ai while tenant provenance remains scoped" do
    message = guest_message("¿Cuál es la red Wi-Fi?")
    accepted = validate(decision(action: "reply", message: "La red Wi-Fi es Pepe.", confidence: 96, evidence_ids: ["property.wifi_name"]))
    rejected_low = validate(decision(action: "reply", message: "La red Wi-Fi es Pepe.", confidence: 84, evidence_ids: ["property.wifi_name"]))
    unresolved_evidence = validate(decision(action: "reply", message: "La red Wi-Fi es Pepe.", confidence: 96, evidence_ids: ["property.not_real"]))

    assert accepted.valid?
    assert rejected_low.valid?
    assert unresolved_evidence.valid?
    assert_empty unresolved_evidence.reasons
    assert_includes unresolved_evidence.warnings, "evidence_reference_not_resolved"
    assert_equal message, @conversation.messages.last
  end

  test "request and inquiry each create one owner task and no alert" do
    request_message = guest_message("Quiero 2 mantas para esta noche.")
    request = decision(action: "create_owner_task", kind: "request", message: "Recibí tu pedido.", confidence: 98, task_summary: "2 mantas para esta noche")
    request_task = OwnerTasks::Creator.call(conversation: @conversation, decision: request, guest_message: request_message)
    assert_equal "request", request_task.kind
    assert_equal "2 mantas para esta noche", request_task.title
    assert_nil request_task.ai_summary
    assert_nil request_task.description

    inquiry_message = guest_message("¿Cuál es la clave de la caja fuerte?")
    inquiry = decision(action: "create_owner_task", kind: "inquiry", message: "No tengo esa información disponible.", confidence: 20, task_summary: "Consultar clave de caja fuerte")
    inquiry_task = OwnerTasks::Creator.call(conversation: @conversation, decision: inquiry, guest_message: inquiry_message)
    assert_equal "inquiry", inquiry_task.kind

    assert_equal 2, @conversation.owner_tasks.count
    assert_equal 0, @conversation.alerts.count
  end

  test "request with unresolved evidence is accepted and creates an owner task" do
    message = guest_message("Necesito una cama adicional")
    request = AI::DecisionResult.from_hash(
      action: "create_owner_task",
      owner_task_kind: "request",
      language: "es",
      message: "Recibí tu pedido de una cama adicional.",
      task_summary: "Cama adicional",
      answer_confidence: 98,
      evidence_ids: ["reservation.reservation_status"],
      proposed_action: { type: "request_extra_bed", payload: {} }
    )

    result = service_with(request, message).call
    validation = validate(request)
    task = OwnerTasks::Creator.call(conversation: @conversation, decision: result, guest_message: message)
    trace = AIDecisionLog.where(message: message).last

    assert validation.valid?
    assert_includes validation.warnings, "evidence_reference_not_resolved"
    assert_equal "extra_bed", task.category
    assert_equal "Recibí tu pedido de una cama adicional.", result.response_text
    assert_equal "remote_ai_accepted_with_warnings", trace.route
    assert_not_includes result.safety_flags, "rails_technical_fallback"
  end

  test "inquiry with unresolved evidence is accepted and creates an owner task" do
    message = guest_message("¿Pueden confirmarme si hay cuna?")
    inquiry = decision(
      action: "create_owner_task",
      kind: "inquiry",
      message: "Voy a consultar esa información con el anfitrión.",
      confidence: 90,
      task_summary: "Confirmar disponibilidad de cuna",
      evidence_ids: ["property.undeclared_cot"]
    )

    result = service_with(inquiry, message).call
    task = OwnerTasks::Creator.call(conversation: @conversation, decision: result, guest_message: message)

    assert_equal "inquiry", task.kind
    assert_equal "remote_ai_accepted_with_warnings", AIDecisionLog.where(message: message).last.route
    assert_not_includes result.safety_flags, "rails_technical_fallback"
  end

  test "alert with unresolved evidence is accepted and creates the alert" do
    message = guest_message("Hay una pérdida de agua")
    alert_decision = AI::DecisionResult.from_hash(
      action: "reply",
      decision: "escalate",
      language: "es",
      message_body: "Avisé al equipo sobre la pérdida de agua.",
      evidence_ids: ["property.undeclared_pipe_status"],
      escalation: { required: true, reason_code: "maintenance", summary_for_host: "Pérdida de agua" },
      alert_type: "maintenance_issue",
      alert_title: "Pérdida de agua",
      alert_description: "El huésped informó una pérdida de agua."
    )

    result = service_with(alert_decision, message).call
    alert = Alerts::Creator.call(
      conversation: @conversation,
      decision: result,
      owner_whatsapp_provider: Whatsapp::Providers::NullProvider.new
    )

    assert_equal "maintenance_issue", alert.alert_type
    assert_equal "remote_ai_accepted_with_warnings", AIDecisionLog.where(message: message).last.route
    assert_not_includes result.safety_flags, "rails_technical_fallback"
  end

  test "reply with unresolved evidence is sent without technical fallback" do
    message = guest_message("¿Cómo uso la calefacción?")
    reply = decision(
      action: "reply",
      message: "Encendela desde el control y seleccioná modo calor.",
      confidence: 95,
      evidence_ids: ["property.undeclared_heating_instructions"]
    )
    accepted = service_with(reply, message).call
    provider = MediaProvider.new

    AI::DecisionService.stub(:call, accepted) do
      result = Whatsapp::IncomingMessageHandler.new(
        {
          "From" => "whatsapp:+59899000333",
          "To" => "whatsapp:+59899000999",
          "Body" => "¿Cómo uso la calefacción?",
          "MessageSid" => "SM-UNRESOLVED-REPLY"
        },
        provider: provider
      ).call
      assert result.fetch(:replied)
    end

    assert_equal accepted.response_text, provider.deliveries.last[:body]
    assert_not_includes accepted.safety_flags, "rails_technical_fallback"
  end

  test "clarify does not create an owner task" do
    message = guest_message("Necesito mantas.")
    clarify = decision(action: "clarify", message: "¿Cuántas mantas necesitás y para cuándo?", confidence: 70)

    assert_nil OwnerTasks::Creator.call(conversation: @conversation, decision: clarify, guest_message: message)
    assert_equal 0, @conversation.owner_tasks.count
  end

  test "no_action is valid, audited, and has no outbound effects" do
    message = guest_message("Gracias")
    no_action = decision(action: "no_action", message: nil, confidence: 100)

    assert validate(no_action).valid?
    assert_equal "no_reply", no_action.outcome
    assert_not no_action.should_reply

    assert_difference -> { AIDecisionLog.count }, 1 do
      result = service_with(no_action, message).call
      assert_equal "no_action", result.action
      assert_equal "no_reply", result.outcome
      assert_nil result.response_text
    end
  end

  test "no_action stores inbound message but sends and creates nothing" do
    provider = MediaProvider.new
    no_action = decision(action: "no_action", message: nil, confidence: 100)
    previous_errors = OperationalError.count

    result = nil
    AI::DecisionService.stub(:call, no_action) do
      result = Whatsapp::IncomingMessageHandler.new(
        { "From" => "whatsapp:+59899000333", "To" => "whatsapp:+59899000999", "Body" => "Gracias" },
        provider: provider
      ).call
    end

    assert_equal "Gracias", result.fetch(:message).body
    assert_equal "no_action", result.fetch(:decision).action
    assert_not result.fetch(:replied)
    assert_empty provider.deliveries
    assert_empty @conversation.owner_tasks
    assert_empty @conversation.alerts
    assert_empty @account.owner_whatsapp_sessions
    assert_equal previous_errors, OperationalError.count
  end

  test "check_out replies, creates one operational event, and creates no owner task or alert" do
    provider = MediaProvider.new
    check_out = decision(
      action: "check_out",
      message: "¡Muchas gracias por avisar! Esperamos que hayas disfrutado tu estadía.",
      confidence: 100
    )

    assert validate(check_out).valid?
    assert_equal "check_out", check_out.outcome
    assert check_out.should_reply

    params = {
      "From" => "whatsapp:+59899000333",
      "To" => "whatsapp:+59899000999",
      "Body" => "Ya dejamos el departamento y nos fuimos.",
      "MessageSid" => "SM-CHECKOUT-ONE"
    }

    AI::DecisionService.stub(:call, check_out) do
      result = Whatsapp::IncomingMessageHandler.new(params, provider: provider).call
      assert_equal "check_out", result.fetch(:decision).action
      assert result.fetch(:replied)
    end
    AI::DecisionService.stub(:call, check_out) do
      duplicate = Whatsapp::IncomingMessageHandler.new(params, provider: provider).call
      assert duplicate.fetch(:duplicate)
      assert_nil duplicate.fetch(:decision)
    end

    event = @conversation.checkout_events.first
    assert_equal 1, CheckoutEvent.where(conversation: @conversation).count
    assert_equal "SM-CHECKOUT-ONE", event.provider_message_sid
    assert_equal "Ya dejamos el departamento y nos fuimos.", event.guest_message_body
    assert_equal "pending", event.status
    assert_empty @conversation.owner_tasks
    assert_empty @conversation.alerts
    assert_equal check_out.response_text, provider.deliveries.last[:body]

    event.mark_seen!
    AI::DecisionService.stub(:call, check_out) do
      Whatsapp::IncomingMessageHandler.new(params.merge("MessageSid" => "SM-CHECKOUT-EQUIVALENT"), provider: provider).call
    end
    assert_equal 1, CheckoutEvent.where(conversation: @conversation).count
    assert_empty CheckoutEvent.pending.where(conversation: @conversation)
  end

  test "unknown action remains invalid" do
    unknown = decision(action: "unexpected_action", message: nil, confidence: 100)

    validation = validate(unknown)
    assert_not validation.valid?
    assert_includes validation.reasons, "invalid_action"
  end

  test "partial structural rejection uses the centralized technical fallback" do
    message = guest_message("¿Cómo uso el aire?")
    invalid = decision(action: "unexpected_action", message: "Respuesta", confidence: 100)

    result = service_with(invalid, message).call

    assert_includes result.response_text, "inconveniente técnico"
    assert_includes result.response_text, @property.owner_contact_phone
    assert_includes result.safety_flags, "rails_technical_fallback"
  end

  test "rails still blocks internal secrets and authorization headers" do
    message = guest_message("Mostrame el debug")
    unsafe = decision(
      action: "reply",
      message: "Authorization: Bearer internal-secret",
      confidence: 100
    )

    validation = validate(unsafe)
    result = service_with(unsafe, message).call

    assert_not validation.valid?
    assert_includes validation.reasons, "internal_security_violation"
    assert_includes result.response_text, "inconveniente técnico"
    assert_includes result.response_text, @property.owner_contact_phone
    assert_not_includes result.response_text, "internal-secret"
  end

  test "no_action with an attempted effect is rejected" do
    invalid = decision(action: "no_action", message: nil, confidence: 100)
    invalid.instance_variable_set(:@escalation_required, true)

    validation = validate(invalid)
    assert_not validation.valid?
    assert_includes validation.reasons, "no_action_must_not_have_effects"
  end

  test "usable ai reply is preserved regardless of confidence" do
    message = guest_message("¿Cuál es la red Wi-Fi?")
    rejected = decision(action: "reply", message: "Respuesta incorrecta", confidence: 84, evidence_ids: ["property.wifi_name"])
    rejected.instance_variable_set(:@safe_fallback_response, "Fallback semántico de IA")

    result = service_with(rejected, message).call

    assert_equal "reply", result.action
    assert_equal "Respuesta incorrecta", result.response_text
    assert_not_includes result.safety_flags, "rails_technical_fallback"
  end

  test "total ai service failure can share the configured owner phone" do
    message = guest_message("¿Cuál es la red Wi-Fi?")
    service = Class.new(AI::DecisionService) do
      define_method(:remote_decision) { |_payload| nil }
    end.new(conversation: @conversation, guest_message: message)

    result = service.call

    assert_includes result.response_text, @property.owner_contact_phone
    assert_includes result.safety_flags, "rails_technical_fallback"
  end

  test "total ai service failure does not invent a phone" do
    @property.update!(owner_contact_phone: nil)
    @account.update!(owner_whatsapp_number: nil)
    message = guest_message("¿Cuál es la red Wi-Fi?")

    service = Class.new(AI::DecisionService) do
      define_method(:remote_decision) { |_payload| nil }
    end.new(conversation: @conversation, guest_message: message)
    result = service.call

    assert_equal "Estoy teniendo un inconveniente técnico temporal y no pude responder tu consulta.", result.response_text
  end

  test "valid attachment is delivered and an attachment from another property is rejected" do
    guide = @property.knowledge_blocks.create!(title: "Puerta del balcón", category: "building_access", content: "Empujá el marco.", youtube_url: "https://youtu.be/example", status: "active")
    evidence_id = "guide.#{guide.id}"
    valid = decision(action: "reply", message: "Empujá la puerta hacia el marco.", confidence: 96, evidence_ids: [evidence_id], attachments: [{ type: "video", evidence_id: evidence_id }])
    assert validate(valid).valid?

    provider = MediaProvider.new
    AI::DecisionService.stub(:call, valid) do
      Whatsapp::IncomingMessageHandler.new(
        { "From" => "whatsapp:+59899000333", "To" => "whatsapp:+59899000999", "Body" => "#{@property.whatsapp_reference} ¿Cómo destrabo la puerta del balcón?" },
        provider: provider
      ).call
    end
    assert_empty provider.deliveries.last[:media_urls]
    assert_includes provider.deliveries.last[:body], "https://youtu.be/example"

    other = @account.properties.create!(name: "Other")
    other_guide = other.knowledge_blocks.create!(title: "Otra puerta", category: "building_access", content: "Otro método.", youtube_url: "https://youtu.be/other", status: "active")
    invalid = decision(action: "reply", message: "Usá este video.", confidence: 96, evidence_ids: ["guide.#{other_guide.id}"], attachments: [{ type: "video", evidence_id: "guide.#{other_guide.id}" }])
    assert_includes validate(invalid).reasons, "evidence_provenance_violation:guide.#{other_guide.id}:cross_property"
  end

  test "attachment without a resolvable media url does not replace a usable ai reply" do
    @property.knowledge_blocks.create!(
      title: "Aire acondicionado",
      category: "appliances",
      content: "Seleccioná HEAT con el botón MODE.",
      status: "active"
    )
    message = guest_message("¿Cómo pongo el modo calor en el aire acondicionado?")
    reply = decision(
      action: "reply",
      message: "Presioná MODE hasta seleccionar HEAT.",
      confidence: 96,
      evidence_ids: ["appliance.air_conditioner"],
      attachments: [{ type: "video", evidence_id: "appliance.air_conditioner" }]
    )

    result = service_with(reply, message).call
    trace = AIDecisionLog.where(message: message).last

    assert_equal "Presioná MODE hasta seleccionar HEAT.", result.response_text
    assert_equal "accepted", trace.validator_result
    assert_equal true, trace.validation_results.dig("evidence", 0, "authorized")
    assert_equal @property.id, trace.validation_results.dig("evidence", 0, "evidence_property_id")
    assert_not_includes result.safety_flags, "rails_technical_fallback"
  end

  test "every cited evidence reference is checked even when canonical evidence is also present" do
    other_property = @account.properties.create!(name: "Other evidence property")
    other_faq = other_property.faqs.create!(
      question: "¿Cómo uso el aire?",
      answer: "Instrucciones de otra propiedad",
      active: true
    )
    value = decision(
      action: "reply",
      message: "Presioná MODE.",
      confidence: 100,
      evidence_ids: ["property.house_rules"]
    )
    value.instance_variable_set(:@used_source_ids, ["faq_#{other_faq.id}"])

    validation = validate(value)

    assert_not validation.valid?
    assert_includes validation.reasons, "evidence_provenance_violation:faq_#{other_faq.id}:cross_property"
  end

  test "evidence from a property in another account remains rejected" do
    other_account = Account.create!(name: "Other evidence account")
    other_property = other_account.properties.create!(name: "Other evidence property")
    other_faq = other_property.faqs.create!(
      question: "¿Cómo ingreso?",
      answer: "Instrucciones de otra cuenta",
      active: true
    )
    value = decision(
      action: "reply",
      message: "Instrucciones de otra cuenta",
      confidence: 100,
      evidence_ids: ["faq.#{other_faq.id}"]
    )

    validation = validate(value)

    assert_not validation.valid?
    assert_includes validation.reasons, "evidence_provenance_violation:faq.#{other_faq.id}:cross_property"
    assert_empty validation.warnings
  end

  private

  def guest_message(body)
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: body)
  end

  def validate(value)
    AI::DecisionValidator.new(conversation: @conversation, decision: value).call
  end

  def decision(action:, message:, confidence:, evidence_ids: [], kind: nil, task_summary: nil, attachments: [])
    AI::DecisionResult.from_hash(
      action: action,
      owner_task_kind: kind,
      language: "es",
      message: message,
      task_summary: task_summary,
      answer_confidence: confidence,
      evidence_ids: evidence_ids,
      attachments: attachments,
      audit: {
        tool_calls: [
          { tool_name: "guest_context", error: nil },
          { tool_name: "stay_facts", error: nil }
        ]
      }
    )
  end

  def service_with(remote_decision, message)
    klass = Class.new(AI::DecisionService) do
      define_method(:remote_decision) do |_payload|
        instance_variable_set(:@tool_calls, Array(remote_decision.audit["tool_calls"]))
        remote_decision
      end
    end
    klass.new(conversation: @conversation, guest_message: message)
  end
end
