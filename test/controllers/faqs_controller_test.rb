require "test_helper"

class FaqsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Bulk FAQ Account")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "bulk-faq-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Palermo")
    @other_property = @account.properties.create!(name: "Recoleta", address: "Arenales 1234")

    sign_in_as(@user)
  end

  test "bulk form lists account properties and preselects the current property" do
    foreign_account = Account.create!(name: "Foreign account")
    foreign_property = foreign_account.properties.create!(name: "Foreign property")

    get bulk_new_property_faqs_path(@property)

    assert_response :success
    assert_includes response.body, "Agregar FAQ en varias propiedades"
    assert_select "input[name='property_ids[]'][value='#{@property.id}'][checked]", count: 1
    assert_select "input[name='property_ids[]'][value='#{@other_property.id}']", count: 1
    assert_select "input[name='property_ids[]'][value='#{foreign_property.id}']", count: 0
    assert_includes response.body, "Propiedad actual"
  end

  test "bulk create makes independent copies in every selected property" do
    assert_difference -> { Faq.count }, 2 do
      post bulk_create_property_faqs_path(@property), params: {
        property_ids: [@property.id, @other_property.id],
        faq: {
          question: "¿Dónde estaciono?",
          answer: "Podés estacionar en la cochera 4.",
          category: "parking",
          status: "approved",
          active: "1"
        }
      }
    end

    assert_redirected_to property_path(@property, anchor: "faqs")
    first_faq = @property.faqs.find_by!(question: "¿Dónde estaciono?")
    second_faq = @other_property.faqs.find_by!(question: "¿Dónde estaciono?")
    assert_not_equal first_faq.id, second_faq.id
    assert_equal "manual", first_faq.source_type
    assert_equal first_faq.metadata["bulk_operation_id"], second_faq.metadata["bulk_operation_id"]
    assert_equal @property.id, first_faq.metadata["bulk_source_property_id"]

    first_faq.update!(answer: "Respuesta editada solo en Palermo.")
    assert_equal "Podés estacionar en la cochera 4.", second_faq.reload.answer
  end

  test "bulk create skips a normalized duplicate without changing it" do
    existing = @property.faqs.create!(
      question: "  ¿DÓNDE   ESTACIONO? ",
      answer: "Respuesta existente.",
      category: "parking",
      status: "approved",
      source_type: "manual",
      active: true
    )

    assert_difference -> { Faq.count }, 1 do
      post bulk_create_property_faqs_path(@property), params: {
        property_ids: [@property.id, @other_property.id],
        faq: {
          question: "¿Dónde estaciono?",
          answer: "Respuesta nueva.",
          category: "parking",
          status: "approved",
          active: "1"
        }
      }
    end

    assert_equal "Respuesta existente.", existing.reload.answer
    assert_equal "Respuesta nueva.", @other_property.faqs.find_by!(question: "¿Dónde estaciono?").answer
    assert_includes flash[:notice], "Se omitió 1 propiedad"
  end

  test "bulk create requires at least one editable property" do
    assert_no_difference -> { Faq.count } do
      post bulk_create_property_faqs_path(@property), params: {
        property_ids: [],
        faq: {
          question: "¿Hay pileta?",
          answer: "Sí.",
          status: "approved",
          active: "1"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Seleccioná al menos una propiedad"
  end

  test "bulk create never writes FAQs into another account" do
    foreign_account = Account.create!(name: "Foreign account")
    foreign_property = foreign_account.properties.create!(name: "Foreign property")

    assert_difference -> { @property.faqs.count }, 1 do
      assert_no_difference -> { foreign_property.faqs.count } do
        post bulk_create_property_faqs_path(@property), params: {
          property_ids: [@property.id, foreign_property.id],
          faq: {
            question: "¿Cuál es el horario?",
            answer: "A las 15.",
            status: "approved",
            active: "1"
          }
        }
      end
    end
  end

  test "invalid bulk FAQ is not created in any selected property" do
    assert_no_difference -> { Faq.count } do
      post bulk_create_property_faqs_path(@property), params: {
        property_ids: [@property.id, @other_property.id],
        faq: {
          question: "¿Cuál es el horario?",
          answer: "",
          status: "approved",
          active: "1"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "property FAQ section links to the bulk form" do
    get property_path(@property)

    assert_response :success
    assert_select "a[href='#{bulk_new_property_faqs_path(@property)}']", text: "Agregar en varias propiedades", count: 1
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end
end
