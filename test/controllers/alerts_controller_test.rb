require "test_helper"

class AlertsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Alert Test")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "alert-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Alert Apartment")
    @guest = @account.guests.create!(phone_number: "+15550001000", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    @alert = @property.alerts.create!(
      guest: @guest,
      conversation: @conversation,
      alert_type: "unknown_question",
      title: "La pregunta necesita respuesta del anfitrión",
      description: "¿Dónde hay toallas extra?",
      status: "open",
      priority: "medium"
    )

    sign_in_as(@user)
  end

  test "answering an unknown question creates active faq and resolves alert" do
    assert_difference -> { @property.faqs.count }, 1 do
      post answer_question_alert_path(@alert), params: {
        faq: {
          question: "¿Dónde hay toallas extra?",
          answer: "Las toallas extra están en el placard del pasillo."
        }
      }
    end

    assert_redirected_to property_path(@property, anchor: "new-questions")
    faq = @property.faqs.order(:created_at).last
    assert_equal "¿Dónde hay toallas extra?", faq.question
    assert_equal "Las toallas extra están en el placard del pasillo.", faq.answer
    assert_equal "custom_notes", faq.category
    assert faq.active?
    assert_equal "resolved", @alert.reload.status
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
