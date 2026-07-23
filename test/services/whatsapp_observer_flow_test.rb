require "test_helper"

class WhatsappObserverFlowTest < ActiveSupport::TestCase
  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(to:, body:, media_urls: [])
      @messages << { to: to, body: body }
      true
    end

    def send_interactive(to:, content_key:, variables: {}, fallback_body:)
      @messages << { to: to, content_key: content_key, body: fallback_body }
      true
    end
  end

  setup do
    @account = Account.create!(
      name: "Observer flow",
      owner_whatsapp_number: "+59899101001",
      owner_whatsapp_escalations_enabled: true,
      observer_mode_enabled: true
    )
    @property = @account.properties.create!(name: "Vista Cordillera")
    @guest = @account.guests.create!(property: @property, phone_number: "+59899102001", name: "Juan Pérez")
    @conversation = @guest.conversations.create!(property: @property)
    @provider = RecordingProvider.new
  end

  test "observer no longer routes or consumes owner messages" do
    AI::DecisionService.stub(:call, ->(*) { raise "AI must not be called" }) do
      result = inbound("Conversaciones", "SM-OBS-NO-ROUTER", "conversaciones")

      assert result[:owner_message]
      assert_nil result[:conversation]
      assert_includes @provider.messages.last[:body], "WhatsApp del *dueño/anfitrión*"
      assert_includes @provider.messages.last[:body], "No tenés pedidos, consultas, alertas ni salidas pendientes"
    end
  end

  test "observer enabled never intercepts an operational reply" do
    guest_message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Necesito una manta")
    task = @conversation.owner_tasks.create!(
      account: @account,
      property: @property,
      guest: @guest,
      message: guest_message,
      kind: "request",
      guest_phone: @guest.phone_number,
      property_name: @property.display_name,
      category: "extra_item",
      title: "Pedido",
      description: guest_message.body,
      source_channel: "whatsapp"
    )
    Whatsapp::OwnerEscalationNotifier.call(account: @account, provider: @provider)

    inbound("Pedidos", "SM-OP-1", "pedidos")
    inbound("Responder", "SM-OP-2", "responder")
    inbound("Te llevamos una manta.", "SM-OP-3")
    inbound("Enviar", "SM-OP-4", "enviar")

    assert_equal "resolved", task.reload.status
    assert_equal "responded", task.response_delivery_state
    assert @provider.messages.any? { |message| message[:to] == @guest.phone_number && message[:body] == "Te llevamos una manta." }
  end

  private

  def inbound(body, sid, action_id = nil)
    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{@account.owner_whatsapp_number}",
        "To" => "whatsapp:+59899999999",
        "Body" => body,
        "ButtonPayload" => action_id,
        "MessageSid" => sid
      }.compact,
      provider: @provider
    ).call
  end
end
