require "test_helper"

class MessageTranslationTest < ActiveSupport::TestCase
  setup do
    account = Account.create!(name: "Translation model")
    property = account.properties.create!(name: "Translated apartment")
    guest = account.guests.create!(phone_number: "+15550101010", property: property)
    conversation = guest.conversations.create!(property: property)
    @message = conversation.messages.create!(sender: "guest", body: "Merhaba", detected_language: "tr")
  end

  test "keeps the original body and stores one translation per target language" do
    @message.message_translations.find_or_initialize_by(target_language: "es").update!(
      source_language: "tr",
      translated_body: "Hola",
      status: "completed"
    )
    duplicate = @message.message_translations.new(
      target_language: "es",
      source_language: "tr",
      translated_body: "Buenas",
      status: "completed"
    )

    assert_not duplicate.valid?
    assert_equal "Merhaba", @message.reload.body
  end
end
