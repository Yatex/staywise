require "test_helper"

class AiTechnicalFallbackTest < ActiveSupport::TestCase
  setup do
    @previous_message = ENV["AI_TECHNICAL_FALLBACK_MESSAGE"]
    @account = Account.create!(name: "Fallback account", owner_whatsapp_number: "+59899111222")
    @property = @account.properties.create!(name: "Fallback property", owner_contact_phone: "+59899000111")
  end

  teardown do
    ENV["AI_TECHNICAL_FALLBACK_MESSAGE"] = @previous_message
  end

  test "classifies an AI service read timeout and includes the configured owner phone" do
    fallback = AI::TechnicalFallback.new(
      property: @property,
      error: Net::ReadTimeout.new("execution expired"),
      duration_ms: 30_100,
      correlation_id: "correlation-1",
      request_id: "request-1"
    )

    assert_equal "AI_TIMEOUT", fallback.type
    assert_includes fallback.message, @property.owner_contact_phone
    assert_includes fallback.message, "inconveniente técnico"
    assert_not_includes fallback.message, "Net::ReadTimeout"
    assert_not_includes fallback.message, "AI service"
    assert_equal 0, fallback.diagnostic[:tools_executed]
    assert_equal "correlation-1", fallback.diagnostic[:correlation_id]
  end

  test "classifies HTTP timeout separately" do
    fallback = AI::TechnicalFallback.new(property: @property, http_status: 504)

    assert_equal "HTTP_TIMEOUT", fallback.type
  end

  test "classifies a non-timeout HTTP failure as a network error" do
    fallback = AI::TechnicalFallback.new(property: @property, http_status: 502)

    assert_equal "NETWORK_ERROR", fallback.type
    assert_equal 502, fallback.diagnostic[:http_status]
  end

  test "classifies a tool timeout and records only the affected tool diagnostics" do
    fallback = AI::TechnicalFallback.new(
      property: @property,
      response_payload: { fallback_diagnostic: { type: "TOOL_TIMEOUT", tool: "property_brain" } },
      tools: [{ tool_name: "property_brain", error: "tool_timeout", latency_ms: 5_000 }]
    )
    diagnostic = fallback.diagnostic

    assert_equal "TOOL_TIMEOUT", diagnostic[:type]
    assert_equal "property_brain", diagnostic[:tool]
    assert_equal 5_000, diagnostic[:tool_duration_ms]
    assert_equal 1, diagnostic[:tools_executed]
    assert_not diagnostic.key?(:backtrace)
  end

  test "classifies OpenAI timeout from the AI service diagnostic" do
    fallback = AI::TechnicalFallback.new(
      property: @property,
      response_payload: {
        fallback_diagnostic: {
          type: "OPENAI_TIMEOUT",
          provider: "openai",
          exception_class: "TimeoutError",
          exception_message: "model timed out"
        }
      }
    )

    assert_equal "OPENAI_TIMEOUT", fallback.type
    assert_equal "TimeoutError", fallback.diagnostic[:exception_class]
  end

  test "classifies network and unexpected errors" do
    network = AI::TechnicalFallback.new(property: @property, error: SocketError.new("getaddrinfo failed"))
    unexpected = AI::TechnicalFallback.new(property: @property, error: ArgumentError.new("unexpected"))

    assert_equal "NETWORK_ERROR", network.type
    assert_equal "INTERNAL_EXCEPTION", unexpected.type
  end

  test "uses the single configurable message template" do
    ENV["AI_TECHNICAL_FALLBACK_MESSAGE"] = "Problema temporal. Urgencias: {{owner_phone}}."

    assert_equal "Problema temporal. Urgencias: #{@property.owner_contact_phone}.",
      AI::TechnicalFallback.new(property: @property).message
  end

  test "removes the owner phone sentence cleanly when no phone is configured" do
    @property.update!(owner_contact_phone: nil)
    @account.update!(owner_whatsapp_number: nil)

    message = AI::TechnicalFallback.new(property: @property).message

    assert_equal "Estoy teniendo un inconveniente técnico temporal y no pude responder tu consulta.", message
    assert_not_includes message, "{{owner_phone}}"
  end
end
