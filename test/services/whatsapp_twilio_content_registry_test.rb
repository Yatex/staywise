require "test_helper"

class WhatsappTwilioContentRegistryTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :account_sid, :created_definitions

    def initialize(contents: [], fail_create: false)
      @account_sid = "AC_TEST_CONTENT"
      @contents = contents
      @fail_create = fail_create
      @created_definitions = []
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

    assert_equal %w[responder siguiente omitir salir], item_ids
    assert_equal %w[enviar editar cancelar], confirm_ids
    assert_equal %w[recordar no_recordar], learning_ids
    assert_no_match(/approval/i, definitions.to_json)
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

  private

  def registry_for(client)
    Whatsapp::TwilioContentRegistry.new(client: client, cache: ActiveSupport::Cache::MemoryStore.new)
  end
end
