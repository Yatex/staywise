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
  end

  test "stay facts returns scoped property and reservation facts" do
    post "/internal/ai/tools/stay_facts", params: {
      conversation_id: @conversation.id,
      requested_fields: ["check_in_time", "reservation_status"]
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal ["property_fact:check_in_time", "reservation_fact:reservation_status"], body.map { |item| item["source_id"] }
  end

  test "search property knowledge returns approximate faq matches" do
    faq = @property.faqs.create!(
      question: "Como bajo a la pileta?",
      answer: "Andá al -1 y después subí por la ventana.",
      category: "amenities",
      active: true
    )

    post "/internal/ai/tools/search_property_knowledge", params: {
      conversation_id: @conversation.id,
      query: "Cómo llego q pileta?"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "faq:#{faq.id}", body.first["source_id"]
    assert_equal "Andá al -1 y después subí por la ventana.", body.first["value"]
  end

  test "approved recommendations returns scoped recommendations" do
    recommendation = @property.recommendations.create!(
      name: "Cafe Tools",
      category: "cafe",
      description: "Good breakfast nearby."
    )

    post "/internal/ai/tools/approved_recommendations", params: {
      conversation_id: @conversation.id,
      category: "coffee"
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "recommendation:#{recommendation.id}", body.first["source_id"]
  end

  test "access instructions are returned only when authorized" do
    post "/internal/ai/tools/access_instructions", params: {
      conversation_id: @conversation.id
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body.map { |item| item["source_id"] }, "property_fact:wifi_password"

    @guest.update!(check_in_date: Date.current + 10.days, checkout_date: Date.current + 12.days)

    post "/internal/ai/tools/access_instructions", params: {
      conversation_id: @conversation.id
    }

    assert_response :success
    denied = JSON.parse(response.body)
    assert_equal true, denied["denied"]
  end
end
