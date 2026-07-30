require "test_helper"

class MessageTranslationsIntegrityCheckerTest < ActiveSupport::TestCase
  test "accepts translations that preserve urls phones times codes and keypad sequences exactly" do
    original = "Llamá al +598 99 123 456 a las 15:30, usá 1234# y mirá https://example.com/a?x=1"
    translated = "Call +598 99 123 456 at 15:30, use 1234#, and see https://example.com/a?x=1"

    assert MessageTranslations::IntegrityChecker.call(original: original, translated: translated)[:valid]
  end

  test "rejects a translation that changes or truncates an operational value" do
    original = "Usá 1234# y mirá https://example.com/a?x=1"
    translated = "Use 1234 and see https://example.com/a"
    result = MessageTranslations::IntegrityChecker.call(original: original, translated: translated)

    assert_not result[:valid]
    assert_includes result[:missing_tokens], "1234#"
    assert_includes result[:missing_tokens], "https://example.com/a?x=1"
  end
end
