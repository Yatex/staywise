require "test_helper"

class ErrorReporterTest < ActiveSupport::TestCase
  test "records operational errors and filters sensitive context" do
    error = ErrorReporter.report(
      RuntimeError.new("Provider exploded"),
      source: "twilio_provider",
      severity: "critical",
      context: {
        token: "secret-token",
        nested: {
          api_key: "secret-key",
          body: "hello"
        }
      }
    )

    assert error.persisted?
    assert_equal "twilio_provider", error.source
    assert_equal "critical", error.severity
    assert_equal "RuntimeError", error.error_class
    assert_equal "Provider exploded", error.message
    assert_equal "[FILTERED]", error.context["token"]
    assert_equal "[FILTERED]", error.context["nested"]["api_key"]
    assert_equal "hello", error.context["nested"]["body"]
  end

  test "normalizes unknown severities" do
    error = ErrorReporter.report(source: "ai_service", severity: "bad", message: "Something happened")

    assert_equal "error", error.severity
  end
end
