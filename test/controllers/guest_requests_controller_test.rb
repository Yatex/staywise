require "test_helper"

class GuestRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Pedidos Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Pedido Owner",
      email: "pedido-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Pedido Apartment", address: "Pedido 123")
    @guest = @account.guests.create!(phone_number: "+15550004000", property: @property)
    @conversation = @guest.conversations.create!(property: @property, status: "active")
    @message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "quiero un vino")
    @guest_request = @conversation.guest_requests.create!(
      account: @account,
      property: @property,
      guest: @guest,
      message: @message,
      guest_phone: @guest.phone_number,
      property_name: @property.display_name,
      property_address: @property.address,
      category: "food_or_drink",
      title: "Pedido de comida o bebida",
      description: "quiero un vino",
      ai_summary: "El huésped pidió un vino.",
      status: "pending",
      priority: "normal",
      source_channel: "whatsapp"
    )

    sign_in_as(@user)
  end

  test "owner can list guest requests" do
    get guest_requests_path

    assert_response :success
    assert_includes @response.body, "Pedidos"
    assert_includes @response.body, "Pedido de comida o bebida"
    assert_includes @response.body, "quiero un vino"
    assert_includes @response.body, "Pedido Apartment"
  end

  test "owner can view and update guest request" do
    get guest_request_path(@guest_request)

    assert_response :success
    assert_includes @response.body, "Quién lo pidió"
    assert_includes @response.body, "Mensaje del huésped"
    assert_includes @response.body, "quiero un vino"
    assert_select "a[href='#{conversation_path(@conversation)}']", text: "Responder al huésped"
    assert_not_includes @response.body, "Resumen de Ayla"
    assert_not_includes @response.body, "Detalles estructurados"
    assert_not_includes @response.body, "El huésped pidió un vino."

    patch guest_request_path(@guest_request), params: {
      guest_request: {
        status: "resolved",
        priority: "high"
      }
    }

    assert_redirected_to guest_request_path(@guest_request)
    assert_equal "resolved", @guest_request.reload.status
    assert_equal "high", @guest_request.priority
    assert_not_nil @guest_request.resolved_at
  end

  test "property filter limits requests" do
    other_property = @account.properties.create!(name: "Other Apartment")
    other_guest = @account.guests.create!(phone_number: "+15550004001", property: other_property)
    other_conversation = other_guest.conversations.create!(property: other_property)
    other_message = other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "necesito toallas")
    other_conversation.guest_requests.create!(
      account: @account,
      property: other_property,
      guest: other_guest,
      message: other_message,
      guest_phone: other_guest.phone_number,
      property_name: other_property.display_name,
      category: "extra_item",
      title: "Pedido de artículo extra",
      description: "necesito toallas",
      status: "pending",
      priority: "normal",
      source_channel: "whatsapp"
    )

    get guest_requests_path(property_id: @property.id)

    assert_response :success
    assert_includes @response.body, "quiero un vino"
    assert_not_includes @response.body, "necesito toallas"
  end

  test "requests and inquiries are listed in separate sections" do
    inquiry_message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Cuál es el código de la ventana?")
    inquiry = @conversation.owner_tasks.create!(
      account: @account, property: @property, guest: @guest, message: inquiry_message,
      kind: "inquiry", guest_phone: @guest.phone_number, property_name: @property.display_name,
      category: "other", title: "Consulta pendiente", description: inquiry_message.body,
      status: "pending", priority: "normal", source_channel: "whatsapp"
    )

    get guest_requests_path
    assert_response :success
    assert_includes response.body, @guest_request.description
    assert_not_includes response.body, inquiry.description

    get inquiries_path
    assert_response :success
    assert_includes response.body, inquiry.description
    assert_not_includes response.body, @guest_request.description
    assert_select "a[href='#{inquiry_path(inquiry)}']"
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
