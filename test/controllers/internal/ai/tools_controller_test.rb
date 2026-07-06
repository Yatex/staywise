require "test_helper"

class InternalAiToolsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Tools Account")
    @property = @account.properties.create!(
      name: "Tools Apartment",
      check_in_time: "15:00",
      checkout_time: "11:00",
      wifi_name: "Tools WiFi",
      wifi_password: "tools-secret"
    )
    @guest = @account.guests.create!(
      phone_number: "+15550002000",
      property: @property,
      check_in_date: Date.current,
      checkout_date: Date.current + 2.days
    )
    @conversation = @guest.conversations.create!(property: @property)
    @message = @conversation.messages.create!(sender: "guest", body: "What time is check-in?", channel: "whatsapp")
    @decision_context_id = AI::DecisionContext.issue(conversation: @conversation, guest_message: @message)
  end

  test "tools require the shared AI service token when configured" do
    previous_token = ENV["AI_SERVICE_TOKEN"]
    ENV["AI_SERVICE_TOKEN"] = "shared-tools-token"

    post "/internal/ai/tools/guest_context", params: {
      decision_context_id: @decision_context_id,
      query: "What time is check-in?"
    }, headers: { "Authorization" => "Bearer wrong-token" }
    assert_response :unauthorized

    post "/internal/ai/tools/guest_context", params: {
      decision_context_id: @decision_context_id,
      query: "What time is check-in?"
    }, headers: { "Authorization" => "Bearer shared-tools-token" }
    assert_response :success
    assert_includes JSON.parse(response.body).fetch("evidence").map { |item| item["evidence_id"] }, "property.check_in_time"
  ensure
    ENV["AI_SERVICE_TOKEN"] = previous_token
  end

  test "guest context returns safe scoped context from signed decision context" do
    post "/internal/ai/tools/guest_context", params: {
      decision_context_id: @decision_context_id,
      query: "What time is check-in?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Tools Apartment", body.dig("property", "name")
    assert_equal "checked_in", body.dig("reservation", "status")
    assert_includes body.fetch("evidence").map { |item| item["evidence_id"] }, "property.check_in_time"
    assert_equal true, body.dig("available_capabilities", "can_view_wifi")
  end

  test "tools reject free conversation ids without signed context" do
    post "/internal/ai/tools/stay_facts", params: {
      conversation_id: @conversation.id,
      requested_fields: ["check_in_time"]
    }

    assert_response :unauthorized
  end

  test "stay facts returns scoped property and reservation facts" do
    post "/internal/ai/tools/stay_facts", params: {
      decision_context_id: @decision_context_id,
      requested_fields: ["check_in_time", "reservation_status"]
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal ["property.check_in_time", "reservation.reservation_status"], body.map { |item| item["evidence_id"] }
  end

  test "property brain returns relevant non-sensitive sources with stable ids" do
    faq = @property.faqs.create!(
      question: "Como bajo a la pileta?",
      answer: "Andá al -1 y después subí por la ventana.",
      category: "amenities",
      active: true
    )

    post "/internal/ai/tools/property_brain", params: {
      decision_context_id: @decision_context_id,
      guest_message: "Cómo llego q pileta?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["guest_authorized"]
    assert_equal @property.public_token, body.dig("property", "id")
    assert_equal "Tools Apartment", body.dig("property", "name")
    source = body.fetch("matched_sources").find { |item| item["id"] == "faq_#{faq.id}" }
    assert source
    assert_equal "faq", source["type"]
    assert_equal "Como bajo a la pileta?", source["title"]
    assert_equal "Andá al -1 y después subí por la ventana.", source["content"]
    assert_not_includes body.fetch("matched_sources").map { |item| item["id"] }, "sensitive_wifi_password"
  end

  test "property brain matches spanish late checkout wording to faq" do
    faq = @property.faqs.create!(
      question: "Can I request late checkout?",
      answer: "Late checkout depends on availability. Ask the host before confirming.",
      category: "checkout",
      active: true
    )

    post "/internal/ai/tools/property_brain", params: {
      decision_context_id: @decision_context_id,
      guest_message: "Puedo hacer más tarde el checkout?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    source_ids = body.fetch("matched_sources").map { |item| item["id"] }
    assert_includes source_ids, "faq_#{faq.id}"
    assert_includes source_ids, "policy_late_checkout"
  end

  test "search property knowledge returns approximate faq matches" do
    faq = @property.faqs.create!(
      question: "Como bajo a la pileta?",
      answer: "Andá al -1 y después subí por la ventana.",
      category: "amenities",
      active: true
    )

    post "/internal/ai/tools/search_property_knowledge", params: {
      decision_context_id: @decision_context_id,
      query: "Cómo llego q pileta?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "faq:#{faq.id}", body.first["source_id"]
    assert_equal "faq.#{faq.id}", body.first["evidence_id"]
    assert_equal "Andá al -1 y después subí por la ventana.", body.first["value"]
  end

  test "search property knowledge matches spanish late checkout wording to faq" do
    faq = @property.faqs.create!(
      question: "Can I request late checkout?",
      answer: "Late checkout depends on availability. Ask the host before confirming.",
      category: "checkout",
      active: true
    )

    post "/internal/ai/tools/search_property_knowledge", params: {
      decision_context_id: @decision_context_id,
      query: "Puedo hacer más tarde el checkout?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "faq:#{faq.id}", body.first["source_id"]
    assert_equal "faq.#{faq.id}", body.first["evidence_id"]
    assert_equal "Late checkout depends on availability. Ask the host before confirming.", body.first["value"]
  end

  test "approved recommendations returns scoped recommendations" do
    recommendation = @property.recommendations.create!(
      name: "Cafe Tools",
      category: "cafe",
      description: "Good breakfast nearby."
    )

    post "/internal/ai/tools/approved_recommendations", params: {
      decision_context_id: @decision_context_id,
      category: "coffee"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "recommendation:#{recommendation.id}", body.first["source_id"]
    assert_equal "recommendation.#{recommendation.id}", body.first["evidence_id"]
  end

  test "access instructions are returned only when authorized" do
    post "/internal/ai/tools/access_instructions", params: {
      decision_context_id: @decision_context_id
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body.map { |item| item["source_id"] }, "property_fact:wifi_password"

    @guest.update!(check_in_date: Date.current + 10.days, checkout_date: Date.current + 12.days)
    new_message = @conversation.messages.create!(sender: "guest", body: "What is the access code?", channel: "whatsapp")
    decision_context_id = AI::DecisionContext.issue(conversation: @conversation, guest_message: new_message)

    post "/internal/ai/tools/access_instructions", params: {
      decision_context_id: decision_context_id
    }

    assert_response :success
    denied = JSON.parse(response.body)
    assert_equal true, denied["denied"]
  end

  test "sensitive access info is returned only when authorized" do
    post "/internal/ai/tools/sensitive_access_info", params: {
      decision_context_id: @decision_context_id,
      guest_message: "What is the WiFi password?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["authorized"]
    assert_includes body.fetch("sources").map { |item| item["id"] }, "sensitive_wifi_password"
    assert_equal "tools-secret", body.fetch("sources").find { |item| item["id"] == "sensitive_wifi_password" }["content"]

    @guest.update!(check_in_date: Date.current + 10.days, checkout_date: Date.current + 12.days)
    new_message = @conversation.messages.create!(sender: "guest", body: "What is the WiFi password?", channel: "whatsapp")
    decision_context_id = AI::DecisionContext.issue(conversation: @conversation, guest_message: new_message)

    post "/internal/ai/tools/sensitive_access_info", params: {
      decision_context_id: decision_context_id,
      guest_message: "What is the WiFi password?"
    }

    assert_response :success
    denied = JSON.parse(response.body)
    assert_equal false, denied["authorized"]
    assert_equal "guest_not_authorized", denied["reason"]
    assert_empty denied["sources"]
  end
end
