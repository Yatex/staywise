require "test_helper"

class PropertiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Property Flow")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "property-owner@staywise.test",
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Step Apartment")

    sign_in_as(@user)
  end

  test "property show and step forms render" do
    get property_path(@property)
    assert_response :success
    assert_includes @response.body, "Dudas nuevas"

    get edit_property_path(@property)
    assert_response :success
    assert_includes @response.body, "Llegada y check-in"
    assert_includes @response.body, "Checkout"

    get new_property_knowledge_block_path(@property)
    assert_response :success
    assert_includes @response.body, "Link de YouTube opcional"
  end

  test "new property form hides intro header and shows initial faq section" do
    get new_property_path

    assert_response :success
    assert_not_includes @response.body, "Volver a propiedades"
    assert_not_includes @response.body, "Agregá los datos principales"
    assert_includes @response.body, "Preguntas frecuentes iniciales"
    assert_includes @response.body, "Agregar FAQ"
  end

  test "creates property with initial faqs" do
    assert_difference -> { @account.properties.count }, 1 do
      assert_difference -> { Faq.count }, 5 do
        post properties_path, params: {
          property: {
            name: "FAQ Apartment",
            initial_faqs: [
              {
                question: "What time is checkout?",
                answer: "Checkout is at 11:00.",
                category: "checkout"
              },
              {
                question: "Where do I leave the keys?",
                answer: "Leave the keys on the dining table.",
                category: "checkout"
              },
              {
                question: "Is there parking?",
                answer: "Street parking is available.",
                category: "parking"
              },
              {
                question: "Can I bring a pet?",
                answer: "Pets need owner approval.",
                category: "rules"
              },
              {
                question: "Where is the trash room?",
                answer: "It is next to the elevator on level -1.",
                category: "building"
              },
              {
                question: "",
                answer: "",
                category: ""
              }
            ]
          }
        }
      end
    end

    property = @account.properties.order(:created_at).last

    assert_redirected_to property_path(property)
    assert_equal [
      "What time is checkout?",
      "Where do I leave the keys?",
      "Is there parking?",
      "Can I bring a pet?",
      "Where is the trash room?"
    ], property.faqs.order(:id).pluck(:question)
  end

  test "does not create property when an initial faq is incomplete" do
    assert_no_difference -> { @account.properties.count } do
      post properties_path, params: {
        property: {
          name: "Incomplete FAQ Apartment",
          initial_faqs: [
            {
              question: "What time is checkout?",
              answer: "",
              category: "checkout"
            }
          ]
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes @response.body, "Completá pregunta y respuesta"
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
