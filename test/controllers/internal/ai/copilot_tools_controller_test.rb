require "test_helper"

class InternalAiCopilotToolsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Copilot Tools")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(name: "Host", email: "copilot-tools@example.test", password: "password123")
    @property = @account.properties.create!(
      name: "Scoped Apartment",
      wifi_name: "Exact Network",
      wifi_password: "ExactPass#7",
      access_instructions: "Use 4821# at the blue door."
    )
    @property.sensitive_data.create!(kind: "door_code", value: "4821#", active: true)
    @other_property = @account.properties.create!(name: "Other Apartment", wifi_password: "NeverLeak")
    @thread = @user.copilot_threads.create!(account: @account, property: @property)
    @message = @thread.copilot_messages.create!(
      account: @account, property: @property, user: @user, role: "host", content: "What is the door code?"
    )
    @token = Copilot::ToolContext.issue(thread: @thread, message: @message)
  end

  test "sensitive access tool returns only the selected property's exact values" do
    post "/internal/ai/copilot_tools/sensitive_access_info", params: {
      decision_context_id: @token,
      guest_message: "What is the door code?"
    }

    assert_response :success
    assert_includes response.body, "4821#"
    assert_not_includes response.body, "NeverLeak"
  end

  test "property brain does not expose sensitive values without the dedicated tool" do
    post "/internal/ai/copilot_tools/property_brain", params: {
      decision_context_id: @token,
      guest_message: "How do I enter?"
    }

    assert_response :success
    assert_not_includes response.body, "4821#"
    assert_not_includes response.body, "ExactPass#7"
  end

  test "tampered cross-property context is rejected" do
    invalid = Copilot::ToolContext.verifier.generate(
      { account_id: @account.id, property_id: @other_property.id, user_id: @user.id, thread_id: @thread.id, message_id: @message.id },
      expires_in: 10.minutes
    )

    post "/internal/ai/copilot_tools/property_brain", params: { decision_context_id: invalid, guest_message: "wifi" }

    assert_response :unauthorized
  end

  test "free property ids cannot be used without a signed context" do
    post "/internal/ai/copilot_tools/property_brain", params: { property_id: @other_property.id, guest_message: "wifi" }

    assert_response :unauthorized
  end
end
