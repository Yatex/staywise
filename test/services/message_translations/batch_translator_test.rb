require "test_helper"

class MessageTranslationsBatchTranslatorTest < ActiveSupport::TestCase
  class Provider < Translation::Provider
    attr_reader :calls

    def initialize
      @calls = []
    end

    def translate_messages(messages:, target_language:, source_language: "auto", context: nil)
      @calls << messages
      Result.new(
        success?: true,
        provider: "test",
        model: "batch",
        translations: messages.map { |message|
          { "id" => message[:id], "source_language" => "tr", "target_language" => target_language,
            "translated_body" => "ES: #{message[:body]}" }
        },
        duration_ms: 10
      )
    end
  end

  class MismatchedProvider < Translation::Provider
    def translate_messages(messages:, target_language:, source_language: "auto", context: nil)
      Result.new(
        success?: false,
        provider: "deepl",
        translations: [],
        error: "DEEPL_RESULT_COUNT_MISMATCH",
        duration_ms: 1
      )
    end
  end

  setup do
    account = Account.create!(name: "Batch translations")
    property = account.properties.create!(name: "Batch property")
    guest = account.guests.create!(phone_number: "+15550108888", property: property, language: "tr")
    @conversation = guest.conversations.create!(property: property)
    @first = @conversation.messages.create!(sender: "guest", body: "Merhaba", detected_language: "tr")
    @second = @conversation.messages.create!(sender: "ai", body: "Nasılsınız?", detected_language: "tr")
    @provider = Provider.new
  end

  test "translates several messages in one provider request and associates results by id" do
    result = MessageTranslations::BatchTranslator.call(
      messages: [@first, @second], target_language: "es", provider: @provider
    )

    assert result.success?
    assert_equal 1, @provider.calls.size
    assert_equal [@first.id, @second.id], @provider.calls.first.map { |item| item[:id] }
    assert_equal "ES: Merhaba", @first.message_translations.find_by!(target_language: "es").translated_body
    assert_equal "ES: Nasılsınız?", @second.message_translations.find_by!(target_language: "es").translated_body
  end

  test "reuses completed translations and only sends new messages" do
    @first.message_translations.create!(target_language: "es", source_language: "tr",
      translated_body: "Hola", status: "completed")

    MessageTranslations::BatchTranslator.call(
      messages: [@first, @second], target_language: "es", provider: @provider
    )

    assert_equal [@second.id], @provider.calls.first.map { |item| item[:id] }
    assert_equal "Hola", @first.message_translations.find_by!(target_language: "es").translated_body
  end

  test "omits messages already written in the target language" do
    spanish = @conversation.messages.create!(sender: "guest", body: "Hola", detected_language: "es")

    MessageTranslations::BatchTranslator.call(
      messages: [@first, spanish], target_language: "es", provider: @provider
    )

    assert_equal [@first.id], @provider.calls.first.map { |item| item[:id] }
    assert_nil spanish.message_translations.find_by(target_language: "es")
  end

  test "only translates messages added after the cached batch" do
    MessageTranslations::BatchTranslator.call(
      messages: [@first, @second], target_language: "es", provider: @provider
    )
    third = @conversation.messages.create!(sender: "guest", body: "Teşekkürler", detected_language: "tr")

    MessageTranslations::BatchTranslator.call(
      messages: [@first, @second, third], target_language: "es", provider: @provider
    )

    assert_equal 2, @provider.calls.size
    assert_equal [third.id], @provider.calls.last.map { |item| item[:id] }
  end

  test "a provider count mismatch does not cache any translation" do
    result = MessageTranslations::BatchTranslator.call(
      messages: [@first, @second], target_language: "es", provider: MismatchedProvider.new
    )

    assert_not result.success?
    assert_equal 0, @conversation.messages.joins(:message_translations).count
    assert_includes result.error, "DEEPL_RESULT_COUNT_MISMATCH"
  end
end
