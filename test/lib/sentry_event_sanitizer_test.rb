require "test_helper"
require "ostruct"

class SentryEventSanitizerTest < ActiveSupport::TestCase
  test "Sentry stays disabled when the DSN is absent" do
    assert ENV["SENTRY_DSN"].blank?
    assert_not Sentry.initialized?
  end

  test "filters request and AI data while retaining safe correlation fields" do
    request = OpenStruct.new(
      url: "https://ayla.test/decide?token=secret",
      data: { guest_message: "texto privado" },
      cookies: "session=secret",
      query_string: "token=secret",
      headers: {
        "Authorization" => "Bearer secret",
        "X-Request-Id" => "request-123",
        "Content-Type" => "application/json"
      }
    )
    event = OpenStruct.new(
      user: { id: 42, email: "guest@example.test" },
      extra: {
        conversation_id: 10,
        prompt: "prompt privado",
        nested: { tool_response: "respuesta privada" }
      },
      contexts: { trace: { property_id: 20, evidence: "contenido privado" } },
      request: request
    )

    sanitized = SentryEventSanitizer.call(event)

    assert_equal({}, sanitized.user)
    assert_equal "[FILTERED]", sanitized.extra[:prompt]
    assert_equal "[FILTERED]", sanitized.extra[:nested][:tool_response]
    assert_equal 10, sanitized.extra[:conversation_id]
    assert_equal 20, sanitized.contexts[:trace][:property_id]
    assert_equal "[FILTERED]", sanitized.contexts[:trace][:evidence]
    assert_nil sanitized.request.data
    assert_nil sanitized.request.cookies
    assert_nil sanitized.request.query_string
    assert_equal(
      { "X-Request-Id" => "request-123", "Content-Type" => "application/json" },
      sanitized.request.headers
    )
  end

  test "drops scanner requests" do
    event = OpenStruct.new(
      user: {},
      extra: {},
      contexts: {},
      request: OpenStruct.new(url: "https://ayla.test/wp-admin/install.php")
    )

    assert_nil SentryEventSanitizer.call(event)
  end

  test "drops console breadcrumbs and sanitizes other breadcrumb data" do
    console = OpenStruct.new(category: "console", data: {}, message: "MODEL_INPUT_TRACE privado")
    http = OpenStruct.new(
      category: "http",
      data: { prompt: "privado", status: 500 },
      message: "falló authorization=Bearer-secret"
    )

    assert_nil SentryEventSanitizer.call_breadcrumb(console)
    sanitized = SentryEventSanitizer.call_breadcrumb(http)
    assert_equal "[FILTERED]", sanitized.data[:prompt]
    assert_equal 500, sanitized.data[:status]
    assert_equal "falló authorization=[FILTERED]", sanitized.message
  end
end
