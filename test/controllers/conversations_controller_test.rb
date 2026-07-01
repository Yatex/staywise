require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  class FailingProvider < Whatsapp::Providers::BaseProvider
    def send_message(to:, body:)
      false
    end
  end

  setup do
    @account = Account.create!(name: "Conversation Stays")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Conversation Owner",
      email: "conversation-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Conversation Apartment")
    @guest = @account.guests.create!(phone_number: "+15550002000", property: @property)
    @conversation = @guest.conversations.create!(property: @property, status: "escalated")
    @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "¿Puedo hacer late checkout?")

    sign_in_as(@user)
  end

  test "owner can reply to guest through ayla whatsapp number" do
    assert_difference -> { @conversation.messages.where(sender: "owner").count }, 1 do
      post reply_conversation_path(@conversation), params: {
        reply: {
          body: "Hola, podemos coordinar late checkout hasta las 12:00."
        }
      }
    end

    owner_message = @conversation.messages.where(sender: "owner").last

    assert_redirected_to conversation_path(@conversation, anchor: "message-#{owner_message.id}")
    assert_equal "whatsapp", owner_message.channel
    assert_equal "Hola, podemos coordinar late checkout hasta las 12:00.", owner_message.body
    assert_equal @user.id, owner_message.metadata["sent_by_user_id"]
    assert_equal "ayla_dashboard", owner_message.metadata["sent_via"]
  end

  test "blank owner reply is rejected" do
    assert_no_difference -> { @conversation.messages.count } do
      post reply_conversation_path(@conversation), params: {
        reply: {
          body: "   "
        }
      }
    end

    assert_redirected_to conversation_path(@conversation)
    assert_equal "Escribí un mensaje para enviar.", flash[:alert]
  end

  test "failed whatsapp delivery does not store owner message" do
    Whatsapp::ProviderFactory.stub(:build, FailingProvider.new) do
      assert_no_difference -> { @conversation.messages.count } do
        post reply_conversation_path(@conversation), params: {
          reply: {
            body: "Intento de respuesta."
          }
        }
      end
    end

    assert_redirected_to conversation_path(@conversation)
    assert_equal "No se pudo enviar el mensaje por WhatsApp. Revisá la configuración del proveedor.", flash[:alert]
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
