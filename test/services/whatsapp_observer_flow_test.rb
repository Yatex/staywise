require "test_helper"

class WhatsappObserverFlowTest < ActiveSupport::TestCase
  class RecordingProvider < Whatsapp::Providers::NullProvider
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(to:, body:, media_urls: [])
      @messages << { type: :message, to: to, body: body }
      true
    end

    def send_template(to:, template_sid:, variables: {})
      @messages << { type: :template, to: to, template_sid: template_sid, variables: variables }
      true
    end

    def send_interactive(to:, content_key:, variables: {}, fallback_body:)
      @messages << { type: :interactive, to: to, content_key: content_key, fallback_body: fallback_body }
      true
    end
  end

  setup do
    @previous_sid = ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
    @account = Account.create!(name: "Observer flow", owner_whatsapp_number: "+59899101001", observer_mode_enabled: true)
    @property = @account.properties.create!(name: "Vista Cordillera")
    @guest = @account.guests.create!(property: @property, phone_number: "+59899102001", name: "Juan Pérez")
    @conversation = @guest.conversations.create!(property: @property)
    @provider = RecordingProvider.new
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = nil
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Cómo abro el balcón?")
      @conversation.messages.create!(sender: "ai", channel: "whatsapp", body: "Levantá la manija y girá la llave.")
    end
  end

  teardown do
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = @previous_sid
  end

  test "exact conversaciones selection bypasses guest ai and shows scoped context and link" do
    AI::DecisionService.stub(:call, ->(*) { raise "AI must not be called" }) do
      inbound(@account.owner_whatsapp_number, "Conversaciones", "SM-OBS-1", "conversaciones")
    end

    detail = @provider.messages.find { |message| message[:body]&.include?("Conversación 1 de 1") }.fetch(:body)
    assert_includes detail, "Vista Cordillera"
    assert_includes detail, "Juan Pérez"
    assert_includes detail, "¿Cómo abro el balcón?"
    assert_includes detail, "Levantá la manija"
    assert_includes detail, "Nuevos mensajes:"
    assert_equal :observer_actions, @provider.messages.find { |message| message[:type] == :interactive }[:content_key]

    inbound(@account.owner_whatsapp_number, "Ver conversación", "SM-OBS-2", "ver_conversacion")
    assert @provider.messages.any? { |message| message[:body]&.include?("/conversations/#{@conversation.id}") }
  end

  test "marking seen affects only the current co-host recipient" do
    co_host = @account.co_hosts.create!(name: "María", whatsapp_number: "+59899101002", observer_mode_enabled: true)
    @property.update!(co_host: co_host)
    Observer::ActivityRecorder.call(conversation: @conversation, direction: "guest", provider: @provider)
    owner_activity = @account.conversation_observer_activities.find_by!(conversation: @conversation)
    co_host_activity = co_host.conversation_observer_activities.find_by!(conversation: @conversation)

    inbound(co_host.whatsapp_number, "Conversaciones", "SM-CO-OBS-1", "conversaciones")
    inbound(co_host.whatsapp_number, "Marcar como vista", "SM-CO-OBS-2", "conversacion_vista")

    assert_nil owner_activity.reload.observer_seen_at
    assert co_host_activity.reload.observer_seen_at.present?
  end

  test "co-host never sees activity from an unassigned property" do
    co_host = @account.co_hosts.create!(name: "María", whatsapp_number: "+59899101003", observer_mode_enabled: true)
    @property.update!(co_host: co_host)
    other_property = @account.properties.create!(name: "Propiedad privada")
    other_guest = @account.guests.create!(property: other_property, phone_number: "+59899102002", name: "Otro")
    other_conversation = other_guest.conversations.create!(property: other_property)
    Whatsapp::ProviderFactory.stub(:build, @provider) do
      other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Mensaje privado")
    end
    Observer::ActivityRecorder.call(conversation: @conversation, direction: "guest", provider: @provider)

    inbound(co_host.whatsapp_number, "Conversaciones", "SM-SCOPE-1", "conversaciones")

    bodies = @provider.messages.filter_map { |message| message[:body] }.join("\n")
    assert_includes bodies, "Vista Cordillera"
    assert_not_includes bodies, "Propiedad privada"
  end

  test "free text in observer session is never sent to the guest" do
    inbound(@account.owner_whatsapp_number, "Conversaciones", "SM-FREE-1", "conversaciones")
    messages_before = @conversation.messages.count

    inbound(@account.owner_whatsapp_number, "Responder cualquier cosa", "SM-FREE-2")

    assert_equal messages_before, @conversation.messages.count
    assert_not @provider.messages.any? { |message| message[:to] == @guest.phone_number }
    assert @provider.messages.any? { |message| message[:body]&.include?("Abrí la conversación en Ayla") }
  end

  test "observer session never replaces an active operational item" do
    operational = @account.owner_whatsapp_sessions.create!(
      participant_phone: @account.owner_whatsapp_number,
      actor_role: "owner",
      state: "viewing_item",
      active_category: "consultas",
      active_item_type: "OwnerTask",
      active_item_id: 456,
      started_at: Time.current,
      expires_at: 30.minutes.from_now
    )

    inbound(@account.owner_whatsapp_number, "Conversaciones", "SM-BLOCK-1", "conversaciones")

    assert_empty @account.observer_whatsapp_sessions.active
    assert_equal 456, operational.reload.active_item_id
    assert @provider.messages.any? { |message| message[:body]&.include?("Terminá primero") }
  end

  private

  def inbound(phone, body, sid, action_id = nil)
    Whatsapp::IncomingMessageHandler.new(
      {
        "From" => "whatsapp:#{phone}",
        "To" => "whatsapp:+59899999999",
        "Body" => body,
        "ButtonPayload" => action_id,
        "MessageSid" => sid
      }.compact,
      provider: @provider
    ).call
  end
end
