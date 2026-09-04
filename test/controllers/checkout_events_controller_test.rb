require "test_helper"

class CheckoutEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Salidas Test")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "salidas-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Apartamento Rambla")
    @guest = @account.guests.create!(name: "Juana Pérez", phone_number: "+59899001122", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Ya dejamos las llaves y nos fuimos.")
    @checkout_event = @account.checkout_events.create!(
      property: @property,
      guest: @guest,
      conversation: @conversation,
      source_message: message,
      reservation_key: "reservation:dashboard-test",
      provider_message_sid: "SM-DASHBOARD-CHECKOUT",
      guest_message_body: message.body,
      checked_out_at: Time.zone.parse("2026-07-15 10:30")
    )

    sign_in_as(@user)
  end

  test "lists historical departures without exposing legacy navigation" do
    get checkout_events_path

    assert_response :success
    assert_select "aside a[href='#{checkout_events_path}']", count: 0
    assert_includes response.body, "Apartamento Rambla"
    assert_includes response.body, "Juana Pérez"
    assert_includes response.body, "Ya dejamos las llaves y nos fuimos."
    assert_includes response.body, "Pendientes (1)"
  end

  test "shows operational detail without reply or learning actions" do
    get checkout_event_path(@checkout_event)

    assert_response :success
    assert_includes response.body, "Caso #CO-#{@checkout_event.id}"
    assert_includes response.body, "La propiedad ya puede revisarse."
    assert_not_includes response.body, "Responder al huésped"
    assert_not_includes response.body, "Recordar"
  end

  test "marks a departure as seen" do
    patch checkout_event_path(@checkout_event)

    assert_redirected_to checkout_event_path(@checkout_event)
    assert_equal "seen", @checkout_event.reload.status
    assert @checkout_event.owner_seen_at.present?
  end

  test "does not expose another owner's departure" do
    other = Account.create!(name: "Otro dueño")
    other_property = other.properties.create!(name: "Propiedad privada")
    other_guest = other.guests.create!(phone_number: "+59899009999", property: other_property)
    other_conversation = other_guest.conversations.create!(property: other_property)
    other_message = other_conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Ya salimos")
    other_event = other.checkout_events.create!(property: other_property, guest: other_guest, conversation: other_conversation,
      source_message: other_message, reservation_key: "reservation:other", guest_message_body: other_message.body,
      checked_out_at: Time.current)

    get checkout_event_path(other_event)

    assert_response :not_found
  end

  test "departures are paginated at twenty five and preserve status filters" do
    26.times do |index|
      message = @conversation.messages.create!(
        sender: "guest",
        channel: "whatsapp",
        body: "Salida paginada #{index}"
      )
      @account.checkout_events.create!(
        property: @property,
        guest: @guest,
        conversation: @conversation,
        source_message: message,
        reservation_key: "reservation:paged-#{index}",
        guest_message_body: message.body,
        checked_out_at: Time.current + index.seconds
      )
    end

    get checkout_events_path(status: "pending")
    assert_response :success
    assert_equal 25, response.body.scan(/Salida paginada \d+/).uniq.size
    assert_select "a", text: "Siguiente", count: 1 do |links|
      assert_includes links.first["href"], "status=pending"
    end

    get checkout_events_path(status: "pending", page: 2)
    assert_response :success
    assert_equal 1, response.body.scan(/Salida paginada \d+/).uniq.size
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
