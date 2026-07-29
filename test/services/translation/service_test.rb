require "test_helper"

class TranslationServiceTest < ActiveSupport::TestCase
  class Provider < Translation::Provider
    attr_reader :calls

    def initialize
      @calls = []
    end

    def translate_messages(messages:, target_language:, source_language: "auto", context: nil)
      @calls << messages
      Result.new(
        success?: true,
        translations: messages.map { |message|
          { "id" => message[:id], "source_language" => "auto", "target_language" => target_language,
            "translated_body" => message[:body] }
        },
        provider: "test",
        duration_ms: 1
      )
    end
  end

  test "splits requests at the message limit" do
    provider = Provider.new
    messages = 51.times.map { |index| { id: index, body: "message #{index}" } }

    results = Translation::Service.translate_messages(
      messages: messages, target_language: "es", primary: provider
    )

    assert_equal 2, results.size
    assert_equal [50, 1], provider.calls.map(&:size)
  end

  test "splits requests before exceeding the character limit" do
    provider = Provider.new
    messages = [
      { id: 1, body: "a" * 20_000 },
      { id: 2, body: "b" * 20_000 }
    ]

    Translation::Service.translate_messages(
      messages: messages, target_language: "es", primary: provider
    )

    assert_equal [1, 1], provider.calls.map(&:size)
  end
end
