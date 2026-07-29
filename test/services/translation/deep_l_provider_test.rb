require "test_helper"

class TranslationDeepLProviderTest < ActiveSupport::TestCase
  setup do
    @previous_env = {
      "DEEPL_API_KEY" => ENV["DEEPL_API_KEY"],
      "DEEPL_API_BASE_URL" => ENV["DEEPL_API_BASE_URL"],
      "DEEPL_OPEN_TIMEOUT_SECONDS" => ENV["DEEPL_OPEN_TIMEOUT_SECONDS"],
      "DEEPL_READ_TIMEOUT_SECONDS" => ENV["DEEPL_READ_TIMEOUT_SECONDS"]
    }
    ENV["DEEPL_API_KEY"] = "test-deepl-key"
    ENV["DEEPL_API_BASE_URL"] = "https://api-free.deepl.test"
    ENV["DEEPL_OPEN_TIMEOUT_SECONDS"] = "2"
    ENV["DEEPL_READ_TIMEOUT_SECONDS"] = "9"
    @provider = Translation::DeepLProvider.new
  end

  teardown do
    @previous_env.each { |key, value| ENV[key] = value }
  end

  test "returns a clear configuration error when the API key is missing" do
    ENV["DEEPL_API_KEY"] = nil

    result = @provider.translate_text(text: "Hola", source_language: "es", target_language: "en")

    assert_not result.success?
    assert_equal "DEEPL_API_KEY_MISSING", result.error
  end

  test "translates one text and normalizes the detected language" do
    requests = []
    response = successful_response([
      { detected_source_language: "ES", text: "Hello at 12:00, code 1234#" }
    ])

    Net::HTTP.stub(:start, http_stub(response, requests)) do
      result = @provider.translate_text(
        text: "Hola a las 12:00, código 1234#",
        source_language: "auto",
        target_language: "en"
      )

      assert result.success?
      assert_equal "Hello at 12:00, code 1234#", result.translations["translated_body"]
      assert_equal "es", result.translations["source_language"]
      assert_equal "deepl", result.provider
    end

    assert_equal 1, requests.size
    payload = JSON.parse(requests.first.body)
    assert_equal ["Hola a las 12:00, código 1234#"], payload["text"]
    assert_equal "EN", payload["target_lang"]
    assert_nil payload["source_lang"]
    assert_equal "DeepL-Auth-Key test-deepl-key", requests.first["Authorization"]
  end

  test "uses one request for a batch and associates results by position" do
    requests = []
    response = successful_response([
      { detected_source_language: "TR", text: "Primero" },
      { detected_source_language: "FR", text: "Segundo" }
    ])

    result = Net::HTTP.stub(:start, http_stub(response, requests)) do
      @provider.translate_messages(
        messages: [{ id: 91, body: "Birinci" }, { id: 42, body: "Deuxième" }],
        source_language: "auto",
        target_language: "es"
      )
    end

    assert result.success?
    assert_equal 1, requests.size
    assert_equal [91, 42], result.translations.map { |translation| translation["id"] }
    assert_equal ["Primero", "Segundo"], result.translations.map { |translation| translation["translated_body"] }
    assert_equal ["tr", "fr"], result.translations.map { |translation| translation["source_language"] }
  end

  test "rejects a result count mismatch without returning partial associations" do
    response = successful_response([
      { detected_source_language: "TR", text: "Solo uno" }
    ])

    result = Net::HTTP.stub(:start, http_stub(response, [])) do
      @provider.translate_messages(
        messages: [{ id: 91, body: "Birinci" }, { id: 42, body: "İkinci" }],
        source_language: "auto",
        target_language: "es"
      )
    end

    assert_not result.success?
    assert_empty result.translations
    assert_equal "DEEPL_RESULT_COUNT_MISMATCH", result.error
  end

  test "uses provider-specific timeouts and does not call the AI service after a timeout" do
    starts = []
    timeout_stub = lambda do |*_args, **options, &_block|
      starts << options
      raise Net::ReadTimeout, "timed out"
    end

    result = Translation::AIServiceProvider.stub(:new, -> { flunk("AI service provider must not be built") }) do
      Net::HTTP.stub(:start, timeout_stub) do
        Translation::Service.translate_messages(
          messages: [{ id: 1, body: "Merhaba" }],
          target_language: "es",
          primary: @provider
        ).first
      end
    end

    assert_not result.success?
    assert_equal "DEEPL_READ_TIMEOUT", result.error
    assert_equal 2, starts.first[:open_timeout]
    assert_equal 9, starts.first[:read_timeout]
  end

  private

  def successful_response(translations)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    body = { translations: translations }.to_json
    response.define_singleton_method(:body) { body }
    response
  end

  def http_stub(response, requests)
    lambda do |*_args, **_options, &block|
      http = Object.new
      http.define_singleton_method(:request) do |request|
        requests << request
        response
      end
      block.call(http)
    end
  end
end
