require "test_helper"

class PropertyImportServiceTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Import Account")
    @property = @account.properties.new
    @previous_ai_service_url = ENV["AI_SERVICE_URL"]
    ENV["AI_SERVICE_URL"] = nil
  end

  teardown do
    ENV["AI_SERVICE_URL"] = @previous_ai_service_url
  end

  test "imports obvious fields from text locally when ai service is not configured" do
    result = AI::PropertyImportService.call(
      account: @account,
      property: @property,
      upload: uploaded_text_file
    )

    assert result.useful?
    assert_equal "Studio Palermo Soho", result.property_attributes["name"]
    assert_equal "Thames 2310, Palermo, Buenos Aires, Argentina.", result.property_attributes["address"]
    assert_equal "15:00", result.property_attributes["check_in_time"]
    assert_equal "11:00", result.property_attributes["checkout_time"]
    assert_equal "Pippa", result.property_attributes["wifi_name"]
    assert_equal "Pippa123", result.property_attributes["wifi_password"]
    assert_includes result.property_attributes["house_rules"], "No fumar"
    assert_includes result.property_attributes["parking_instructions"], "estacionamiento pago"
    assert_includes result.property_attributes["ai_general_notes"], "pileta"
    assert_not_includes result.property_attributes["ai_general_notes"], "lavarropas"
    assert_includes result.appliance_guides.map { |guide| guide["title"] }, "Aire acondicionado"
    assert_includes result.appliance_guides.map { |guide| guide["title"] }, "Lavarropas y lavadero"
    assert_includes result.recommendations.map { |recommendation| recommendation["name"] }, "Birkin Coffee Bar"
    assert_equal "Puedo invitar gente a la pileta?", result.faqs.second["question"]
    assert_includes result.faqs.second["answer"], "No"
  end

  test "imports checkout instructions into their dedicated field" do
    upload = uploaded_file_with(<<~TEXT)
      Nombre de la propiedad:
      Casa de prueba

      Checkout hasta las 11:00.

      Instrucciones de salida:
      Dejá las llaves sobre la mesa.
      Sacá la basura y apagá las luces antes de salir.
    TEXT

    result = AI::PropertyImportService.call(
      account: @account,
      property: @property,
      upload: upload
    )

    assert_equal "11:00", result.property_attributes["checkout_time"]
    assert_includes result.property_attributes["checkout_instructions"], "llaves sobre la mesa"
    assert_includes result.property_attributes["checkout_instructions"], "apagá las luces"
    assert_not_includes result.property_attributes.fetch("ai_general_notes", ""), "llaves sobre la mesa"
  end

  test "merges ai import with local extraction when ai misses obvious text fields" do
    ENV["AI_SERVICE_URL"] = "https://ai-service.test"
    service_class = Class.new(AI::PropertyImportService) do
      define_method(:remote_import) do |_document|
        AI::PropertyImportService::Result.new(
          property_attributes: { "checkout_time" => "11:30" },
          faqs: [],
          source_summary: "AI extracted checkout only."
        )
      end
    end
    service = service_class.new(account: @account, property: @property, upload: uploaded_text_file)

    result = service.call

    assert_equal "Studio Palermo Soho", result.property_attributes["name"]
    assert_equal "Pippa", result.property_attributes["wifi_name"]
    assert_equal "11:30", result.property_attributes["checkout_time"]
    assert_operator result.faqs.count, :>, 1
  end

  private

  def uploaded_text_file
    Rack::Test::UploadedFile.new(
      Rails.root.join("tmp/ayla_property_import_test.txt"),
      "text/plain",
      original_filename: "ayla_property_import_test.txt"
    )
  end

  def uploaded_file_with(content)
    file = Tempfile.new(["property-import", ".txt"])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "property.txt")
  end
end
