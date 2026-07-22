require "test_helper"

class ErrorReporterTest < ActiveSupport::TestCase
  class SafeScope
    attr_reader :level, :tags, :contexts

    def set_level(level)
      @level = level
    end

    def set_tags(tags)
      @tags = tags
    end

    def set_context(name, context)
      @contexts ||= {}
      @contexts[name] = context
    end
  end

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

  test "records useful validation details for an invalid active record" do
    account = Account.new
    account.validate
    exception = ActiveRecord::RecordInvalid.new(account)

    error = ErrorReporter.report(exception, source: "whatsapp_webhook", severity: "critical")

    assert_equal "Account", error.context["record_model"]
    assert_includes error.context["record_error_attributes"], "name"
    assert error.context["record_errors"].any? { |message| message.include?("Nombre") }
    assert_not_includes error.message, "Translation missing"
  end

  test "reports an unhandled service exception to Sentry with safe correlation only" do
    scope = SafeScope.new
    captured = nil
    exception = RuntimeError.new("AI connection failed")
    Current.request_id = "request-456"

    Sentry.stub(:initialized?, true) do
      Sentry.stub(:with_scope, ->(&block) { block.call(scope) }) do
        Sentry.stub(:capture_exception, ->(error) { captured = error }) do
          ErrorReporter.report(
            exception,
            source: "ai_service",
            context: {
              conversation_id: 12,
              property_id: 34,
              guest_message: "contenido privado",
              prompt: "prompt privado"
            }
          )
        end
      end
    end

    assert_same exception, captured
    assert_equal "request-456", scope.tags[:request_id]
    assert_equal "ai_service", scope.tags[:source]
    assert_equal({ "conversation_id" => 12, "property_id" => 34 }, scope.contexts["operation"])
  ensure
    Current.reset
  end
end
