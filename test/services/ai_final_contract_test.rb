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

  test "reply requires configured answer confidence and scoped evidence" do
    message = guest_message("¿Cuál es la red Wi-Fi?")
    accepted = validate(decision(action: "reply", message: "La red Wi-Fi es Pepe.", confidence: 96, evidence_ids: ["property.wifi_name"]))
    rejected_low = validate(decision(action: "reply", message: "La red Wi-Fi es Pepe.", confidence: 84, evidence_ids: ["property.wifi_name"]))
    rejected_evidence = validate(decision(action: "reply", message: "La red Wi-Fi es Pepe.", confidence: 96, evidence_ids: ["property.not_real"]))

    assert accepted.valid?
    assert_includes rejected_low.reasons, "answer_confidence_below_threshold"
    assert_includes rejected_evidence.reasons, "invalid_evidence:property.not_real"
    assert_equal message, @conversation.messages.last
  end

  test "request and inquiry each create one owner task and no alert" do
    request_message = guest_message("Quiero 2 mantas para esta noche.")
    request = decision(action: "create_owner_task", kind: "request", message: "Recibí tu pedido.", confidence: 98, task_summary: "2 mantas para esta noche")
    request_task = OwnerTasks::Creator.call(conversation: @conversation, decision: request, guest_message: request_message)
    assert_equal "request", request_task.kind
    assert_equal "2 mantas para esta noche", request_task.ai_summary

    inquiry_message = guest_message("¿Cuál es la clave de la caja fuerte?")
    inquiry = decision(action: "create_owner_task", kind: "inquiry", message: "No tengo esa información disponible.", confidence: 20, task_summary: "Consultar clave de caja fuerte")
    inquiry_task = OwnerTasks::Creator.call(conversation: @conversation, decision: inquiry, guest_message: inquiry_message)
    assert_equal "inquiry", inquiry_task.kind

    assert_equal 2, @conversation.owner_tasks.count
    assert_equal 0, @conversation.alerts.count
  end

  test "clarify does not create an owner task" do
    message = guest_message("Necesito mantas.")
    clarify = decision(action: "clarify", message: "¿Cuántas mantas necesitás y para cuándo?", confidence: 70)

    assert_nil OwnerTasks::Creator.call(conversation: @conversation, decision: clarify, guest_message: message)
    assert_equal 0, @conversation.owner_tasks.count
  end

  test "technical fallback uses property phone and ignores AI safe fallback" do
    message = guest_message("¿Cuál es la red Wi-Fi?")
    rejected = decision(action: "reply", message: "Respuesta incorrecta", confidence: 84, evidence_ids: ["property.wifi_name"])
    rejected.instance_variable_set(:@safe_fallback_response, "Fallback semántico de IA")

    result = service_with(rejected, message).call

    assert_equal "reply", result.action
    assert_includes result.response_text, @property.owner_contact_phone
    assert_not_includes result.response_text, "Fallback semántico"
    assert_includes result.safety_flags, "rails_technical_fallback"
  end

  test "technical fallback does not invent a phone" do
    @property.update!(owner_contact_phone: nil)
    @account.update!(owner_whatsapp_number: nil)
    message = guest_message("¿Cuál es la red Wi-Fi?")

    result = service_with(decision(action: "reply", message: "Respuesta incorrecta", confidence: 84, evidence_ids: ["property.wifi_name"]), message).call

    assert_equal "No pude procesar tu mensaje en este momento.", result.response_text
    assert OperationalError.where(source: "ai_validation", message: "Technical fallback has no owner contact phone").exists?
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
    assert_includes validate(invalid).reasons, "invalid_attachment_evidence:guide.#{other_guide.id}"
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
