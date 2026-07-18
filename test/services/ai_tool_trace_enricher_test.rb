require "test_helper"

class AiToolTraceEnricherTest < ActiveSupport::TestCase
  setup do
    @account = Account.create!(name: "Trace Account")
    @property = @account.properties.create!(name: "Trace Apartment")
    @guest = @account.guests.create!(
      phone_number: "+59899001122",
      property: @property,
      reservation_reference: "RES-2026-44"
    )
    @conversation = @guest.conversations.create!(property: @property)
    @message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Cómo ingreso?")

    @other_account = Account.create!(name: "Other Account")
    @other_property = @other_account.properties.create!(name: "Other Apartment")
  end

  test "enriches each tool with authoritative rails context full evidence and validation" do
    result = AI::ToolTraceEnricher.new(
      conversation: @conversation,
      guest_message: @message,
      decision_context_id: "signed-decision-context",
      referenced_evidence_ids: ["faq.72", "faq.99"],
      tool_calls: [{
        tool_name: "property_brain",
        input: { guest_message: "¿Cómo ingreso?", limit: 8 },
        output: {
          matched_sources: [
            { evidence_id: "faq.72", content: "Ingresá por la puerta lateral." },
            { evidence_id: "faq.99", content: "Contenido de otra propiedad." }
          ]
        },
        latency_ms: 12
      }],
      evidence_catalog: [
        {
          evidence_id: "faq.72",
          raw_id: "faq.72",
          label: "Cómo ingresar",
          source_type: "faq",
          value: "Ingresá por la puerta lateral.",
          tool_name: "property_brain",
          metadata: {
            property_id: @property.id,
            account_id: @account.id,
            scope: "property"
          }
        },
        {
          evidence_id: "faq.99",
          raw_id: "faq.99",
          label: "FAQ incorrecta",
          source_type: "faq",
          value: "Contenido de otra propiedad.",
          tool_name: "property_brain",
          metadata: {
            property_id: @other_property.id,
            account_id: @other_account.id,
            scope: "property"
          }
        }
      ],
      validation_results: {
        evidence: [
          {
            evidence_id: "faq.72",
            authorized: true,
            valid: true,
            scope: "property",
            provenance_reason: "property_match"
          },
          {
            evidence_id: "faq.99",
            authorized: false,
            valid: false,
            scope: "property",
            provenance_reason: "cross_property"
          }
        ]
      }
    ).call

    tool = result.fetch(0)
    context = tool.fetch("context")
    assert_equal @conversation.id, context["conversation_id"]
    assert_equal "RES-2026-44", context["reservation_id"]
    assert_equal @property.id, context["property_id"]
    assert_equal "Trace Apartment", context["property_name"]
    assert_equal @account.id, context["account_id"]
    assert_equal "Trace Account", context["account_name"]
    assert_match(/\Asha256:[a-f0-9]{16}\z/, context["decision_context_fingerprint"])
    assert_equal "¿Cómo ingreso?", tool.dig("request", "guest_message")
    assert_equal "Ingresá por la puerta lateral.", tool.dig("response", "matched_sources", 0, "content")

    returned = tool.fetch("evidence_returned")
    assert_equal 2, returned.size
    assert_equal 2, tool.fetch("evidence_referenced").size

    valid_evidence = returned.find { |item| item["evidence_id"] == "faq.72" }
    assert_equal "Trace Apartment", valid_evidence["property_name"]
    assert_equal "Ingresá por la puerta lateral.", valid_evidence["content"]
    assert_equal true, valid_evidence["validation_passed"]
    assert_equal "Property matches conversation", valid_evidence["validation_label"]

    cross_property = returned.find { |item| item["evidence_id"] == "faq.99" }
    assert_equal "Other Apartment", cross_property["property_name"]
    assert_equal "Other Account", cross_property["account_name"]
    assert_equal false, cross_property["validation_passed"]
    assert_equal "Cross-property evidence", cross_property["validation_label"]
  end

  test "trace sanitizer redacts sensitive evidence content and raw decision context tokens" do
    sanitized = AIDecisionLog.sanitize_trace(
      {
        decision_context_id: "signed-secret-context",
        decision_context_fingerprint: "sha256:1234567890abcdef",
        evidence: {
          field: "wifi_password",
          content: "SuperSecret123",
          value: "SuperSecret123"
        }
      }
    )

    assert_equal "[REDACTED]", sanitized["decision_context_id"]
    assert_equal "sha256:1234567890abcdef", sanitized["decision_context_fingerprint"]
    assert_equal "[REDACTED]", sanitized.dig("evidence", "content")
    assert_equal "[REDACTED]", sanitized.dig("evidence", "value")
    assert_not_includes sanitized.to_json, "SuperSecret123"
  end
end
