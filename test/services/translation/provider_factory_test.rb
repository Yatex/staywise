require "test_helper"

class TranslationProviderFactoryTest < ActiveSupport::TestCase
  setup do
    @previous_provider = ENV["TRANSLATION_PROVIDER"]
  end

  teardown do
    ENV["TRANSLATION_PROVIDER"] = @previous_provider
  end

  test "selects DeepL from configuration" do
    ENV["TRANSLATION_PROVIDER"] = "deepl"

    assert_instance_of Translation::DeepLProvider,
      Translation::ProviderFactory.build
  end

  test "keeps the AI service provider available" do
    ENV["TRANSLATION_PROVIDER"] = "ai_service"

    assert_instance_of Translation::AIServiceProvider,
      Translation::ProviderFactory.build
  end

  test "rejects unknown providers" do
    error = assert_raises(ArgumentError) do
      Translation::ProviderFactory.build(name: "unknown")
    end

    assert_includes error.message, "Unsupported TRANSLATION_PROVIDER"
  end
end
