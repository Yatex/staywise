require "test_helper"

class WhatsappTwilioContentRegistryTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :account_sid, :created_definitions, :approval_submissions

    def initialize(contents: [], fail_create: false)
      @account_sid = "AC_TEST_CONTENT"
      @contents = contents
      @fail_create = fail_create
      @created_definitions = []
      @approval_submissions = []
      @mutex = Mutex.new
    end

    def configured?
      true
    end

    def list_contents
      @mutex.synchronize { @contents.deep_dup }
    end

    def create_content(definition)
      raise "Twilio unavailable" if @fail_create

      sleep 0.02
      @mutex.synchronize do
        @created_definitions << definition.deep_dup
        content = definition.merge("sid" => "HX#{(@contents.length + 1).to_s.rjust(32, '0')}")
        @contents << content
        content.deep_dup
      end
    end

    def fetch_whatsapp_approval(_content_sid)
      {}
    end

    def submit_whatsapp_approval(content_sid, name:, category:)
      @approval_submissions << { content_sid: content_sid, name: name, category: category }
      { "status" => "received", "name" => name, "category" => category }
    end
  end

  test "reuses an existing content resource by stable friendly name" do
    definition = Whatsapp::TwilioContentRegistry::DEFINITIONS.fetch(:item_actions)
    client = FakeClient.new(contents: [definition.merge("sid" => "HX_EXISTING")])
    registry = registry_for(client)

    assert_equal "HX_EXISTING", registry.fetch(:item_actions)
    assert_empty client.created_definitions
  end

  test "creates a missing content once and reuses the cached SID" do
    client = FakeClient.new
    registry = registry_for(client)

    first = registry.fetch(:confirm_reply)
    second = registry.fetch(:confirm_reply)

    assert_equal first, second
    assert_equal 1, client.created_definitions.size
    assert_equal "ayla_owner_confirm_reply_v1", client.created_definitions.first["friendly_name"]
  end

  test "concurrent requests create one content resource" do
    client = FakeClient.new
    registry = registry_for(client)

    results = 2.times.map do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { registry.fetch(:learning) } }
    end.map(&:value)

    assert_equal 1, results.uniq.size
    assert_equal 1, client.created_definitions.size
  end

  test "a fresh application cache finds the remote content instead of creating a duplicate" do
    client = FakeClient.new
    first_registry = registry_for(client)
    sid = first_registry.fetch(:item_actions)

    restarted_registry = registry_for(client)

    assert_equal sid, restarted_registry.fetch(:item_actions)
    assert_equal 1, client.created_definitions.size
  end

  test "definitions preserve every interactive action id and never include approval requests" do
    definitions = Whatsapp::TwilioContentRegistry::DEFINITIONS
    item_ids = definitions.dig(:item_actions, "types", "twilio/list-picker", "items").map { |item| item["id"] }
    confirm_ids = definitions.dig(:confirm_reply, "types", "twilio/quick-reply", "actions").map { |action| action["id"] }
    learning_ids = definitions.dig(:learning, "types", "twilio/quick-reply", "actions").map { |action| action["id"] }
    checkout_ids = definitions.dig(:checkout_actions, "types", "twilio/quick-reply", "actions").map { |action| action["id"] }
    notice = definitions.fetch(:owner_escalation_notice_with_checkouts)
    notice_ids = notice.dig("types", "twilio/quick-reply", "actions").map { |action| action["id"] }
    observer_notice = definitions.fetch(:owner_observer_activity_notice)

    assert_equal %w[responder siguiente omitir salir], item_ids
    assert_equal %w[enviar editar cancelar], confirm_ids
    assert_equal %w[recordar no_recordar], learning_ids
    assert_equal %w[checkout_visto siguiente salir], checkout_ids
    assert_equal %w[pedidos consultas alertas checkouts], notice_ids
    assert_equal ["twilio/text"], observer_notice.fetch("types").keys
    assert_equal({ "1" => "Hay actividad nueva en una conversación. Huésped: Juan Pérez. Propiedad: Palermo Soho.",
                   "2" => "https://aylamanager.com/conversations/123" }, observer_notice.fetch("variables"))
    assert_equal({ "1" => "2", "2" => "1", "3" => "1", "4" => "1" }, notice.fetch("variables"))
    assert_equal "owner_escalation_notice_with_checkouts_v1", notice.fetch("friendly_name")
    assert_equal "owner_observer_activity_notice_v2", observer_notice.fetch("friendly_name")
    observer_body = observer_notice.dig("types", "twilio/text", "body")
    assert_match(/\AAyla te avisa:/, observer_body)
    assert_match(/Notificación automática de Ayla\.\z/, observer_body)
    assert_no_match(/approval/i, definitions.to_json)
  end

  test "provisions observer notice for approval without changing runtime sid" do
    previous_sid = ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = "HX_APPROVED_OBSERVER"
    client = FakeClient.new
    registry = registry_for(client)

    result = registry.provision_and_submit_observer_notice

    definition = client.created_definitions.find { |item| item["friendly_name"] == "owner_observer_activity_notice_v2" }
    assert definition.present?
    assert_equal "twilio/text", definition.fetch("types").keys.first
    assert_includes definition.dig("types", "twilio/text", "body"), "{{2}}"
    assert_equal "UTILITY", client.approval_submissions.first.fetch(:category)
    assert_equal "HX_APPROVED_OBSERVER", ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"]
    assert result.fetch("sid").present?
  ensure
    ENV["TWILIO_OWNER_OBSERVER_NOTICE_CONTENT_SID"] = previous_sid
  end

  test "provisions the versioned owner notice once and submits it without changing runtime configuration" do
    previous_sid = ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
    ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"] = "HX_OLD_APPROVED"
    client = FakeClient.new
    registry = registry_for(client)

    first = registry.provision_and_submit_owner_notice
    second_sid = registry.fetch(:owner_escalation_notice_with_checkouts)

    assert_equal first.fetch("sid"), second_sid
    assert_equal 1, client.created_definitions.count { |definition| definition["friendly_name"] == "owner_escalation_notice_with_checkouts_v1" }
    assert_equal 1, client.approval_submissions.size
    assert_equal "UTILITY", client.approval_submissions.first.fetch(:category)
    assert_equal "HX_OLD_APPROVED", ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
  ensure
    ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"] = previous_sid
  end

  test "detects checkout support from the configured content SID" do
    definition = Whatsapp::TwilioContentRegistry::DEFINITIONS.fetch(:owner_escalation_notice_with_checkouts)
    client = FakeClient.new(contents: [definition.merge("sid" => "HX_CHECKOUTS")])
    registry = registry_for(client)

    assert registry.supports_action?("HX_CHECKOUTS", "checkouts")
    assert_not registry.supports_action?("HX_CHECKOUTS", "unknown")
  end

  test "validates content variable keys against the configured Twilio content" do
    definition = Whatsapp::TwilioContentRegistry::DEFINITIONS.fetch(:owner_observer_activity_notice)
    client = FakeClient.new(contents: [definition.merge("sid" => "HX_OBSERVER")])
    registry = registry_for(client)

    valid = registry.validate_variables("HX_OBSERVER", { "1" => "Resumen", "2" => "https://example.test" })
    invalid = registry.validate_variables("HX_OBSERVER", { "1" => "Resumen" })

    assert valid.valid?
    assert_equal %w[1 2], valid.expected_keys
    assert_not invalid.valid?
    assert_equal "twilio_template_variable_mismatch", invalid.error
  end

  test "rejects validation when the configured content SID does not exist" do
    validation = registry_for(FakeClient.new).validate_variables("HX_UNKNOWN", { "1" => "Resumen" })

    assert_not validation.valid?
    assert_equal "twilio_content_not_found", validation.error
  end

  test "returns nil and reports a clear error when Twilio creation fails" do
    client = FakeClient.new(fail_create: true)
    registry = registry_for(client)
    reported = nil

    ErrorReporter.stub(:report, ->(*args, **kwargs) { reported = [args, kwargs] }) do
      assert_nil registry.fetch(:learning)
    end

    assert_equal "twilio_content_registry", reported.last.fetch(:source)
    assert_equal "learning", reported.last.dig(:context, :content_key)
  end

  test "does not silently reuse a stable friendly name with different action ids" do
    definition = Whatsapp::TwilioContentRegistry::DEFINITIONS.fetch(:owner_escalation_notice_with_checkouts)
    incompatible = definition.deep_dup
    incompatible["sid"] = "HX_WRONG_ACTIONS"
    incompatible.dig("types", "twilio/quick-reply", "actions").last["id"] = "otra_cosa"
    client = FakeClient.new(contents: [incompatible])
    reported = nil

    ErrorReporter.stub(:report, ->(*args, **kwargs) { reported = [args, kwargs] }) do
      assert_nil registry_for(client).fetch(:owner_escalation_notice_with_checkouts)
    end

    assert_match(/incompatible action IDs/, reported.first.first.message)
    assert_empty client.created_definitions
  end

  private

  def registry_for(client)
    Whatsapp::TwilioContentRegistry.new(client: client, cache: ActiveSupport::Cache::MemoryStore.new)
  end
end
