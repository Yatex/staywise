require "test_helper"

class PropertiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = Account.create!(name: "Property Flow")
    @account.subscriptions.create!(plan: "growth", status: "trialing")
    @user = @account.users.create!(
      name: "Owner",
      email: "property-owner@staywise.test",
      email_verified_at: Time.current,
      password: "password123",
      password_confirmation: "password123"
    )
    @property = @account.properties.create!(name: "Step Apartment")

    sign_in_as(@user)
  end

  test "property show and step forms render" do
    @property.knowledge_blocks.create!(
      title: "Lavarropas",
      category: "appliances",
      content: "Usar programa rápido y agregar una ficha.",
      status: "active"
    )

    get property_path(@property)
    assert_response :success
    assert_includes @response.body, "Consultas pendientes"
    assert_includes @response.body, "Electrodomésticos"
    assert_includes @response.body, "Lavarropas"
    assert_includes @response.body, new_property_knowledge_block_path(@property, category: "appliances")
    assert_not_includes @response.body, "Guía del huésped"
    assert_select "section#alerts", count: 0
    assert_select "section#conversations", count: 0

    get edit_property_path(@property)
    assert_response :success
    assert_includes @response.body, "Llegada y check-in"
    assert_includes @response.body, "Checkout"
    assert_includes @response.body, "Instrucciones de salida"
    assert_includes @response.body, "Electrodomésticos"
    assert_includes @response.body, "Recomendaciones locales"

    get new_property_knowledge_block_path(@property)
    assert_response :success
    assert_includes @response.body, "Link de YouTube opcional"
  end

  test "new appliance guide preselects appliance category" do
    get new_property_knowledge_block_path(@property, category: "appliances")

    assert_response :success
    assert_select "select[name='knowledge_block[category]'] option[selected][value='appliances']", text: "Electrodomésticos"
    assert_includes @response.body, "Lavarropas, aire acondicionado, TV, horno"
  end

  test "new property form hides intro header and shows initial faq section" do
    get new_property_path

    assert_response :success
    assert_not_includes @response.body, "Volver a propiedades"
    assert_not_includes @response.body, "Agregá los datos principales"
    assert_includes @response.body, "Electrodomésticos"
    assert_includes @response.body, "FAQs"
    assert_includes @response.body, "Recomendaciones locales"
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

  test "creates property with checkout instructions appliances and recommendations" do
    assert_difference -> { @account.properties.count }, 1 do
      assert_difference -> { KnowledgeBlock.where(category: "appliances").count }, 1 do
        assert_difference -> { Recommendation.count }, 1 do
          post properties_path, params: {
            property: {
              name: "Structured Apartment",
              checkout_time: "11:00",
              checkout_instructions: "Dejá las llaves sobre la mesa.",
              initial_appliance_guides: [
                {
                  title: "Lavarropas",
                  content: "Usá una ficha y el programa rápido.",
                  youtube_url: ""
                }
              ],
              initial_recommendations: [
                {
                  name: "Café Central",
                  category: "cafe",
                  description: "Buen desayuno.",
                  address: "Calle 123",
                  distance_or_walking_time: "5 min"
                }
              ]
            }
          }
        end
      end
    end

    property = @account.properties.order(:created_at).last
    assert_equal "Dejá las llaves sobre la mesa.", property.checkout_instructions
    assert_equal "Lavarropas", property.knowledge_blocks.find_by(category: "appliances").title
    assert_equal "Café Central", property.recommendations.first.name
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

  test "previews property import on create without saving" do
    result = AI::PropertyImportService::Result.new(
      property_attributes: {
        "name" => "Pippa Loft",
        "wifi_name" => "Pippa",
        "wifi_password" => "Pippa123",
        "checkout_time" => "11:00",
        "checkout_instructions" => "Dejá las llaves sobre la mesa."
      },
      appliance_guides: [
        {
          "title" => "Cafetera",
          "content" => "Usá cápsulas Nespresso."
        }
      ],
      faqs: [
        {
          "question" => "¿Cómo bajo a la pileta?",
          "answer" => "Andá al -1 y después subí por la ventana.",
          "category" => "amenities"
        }
      ],
      recommendations: [
        {
          "name" => "Café Central",
          "category" => "cafe",
          "description" => "Buen desayuno."
        }
      ],
      source_summary: "Datos extraídos del archivo."
    )

    assert_no_difference -> { @account.properties.count } do
      AI::PropertyImportService.stub(:call, result) do
        post properties_path, params: {
          preview_import: "1",
          property: {
            name: "",
            initial_faqs: [
              { question: "", answer: "", category: "" }
            ]
          },
          property_import: {
            file: uploaded_text_file
          }
        }
      end
    end

    assert_response :unprocessable_content
    assert_select "input[name='property[name]'][value='Pippa Loft']"
    assert_select "input[name='property[wifi_name]'][value='Pippa']"
    assert_select "input[name='property[wifi_password]'][value='Pippa123']"
    assert_select "textarea[name='property[checkout_instructions][]']", count: 0
    assert_select "textarea[name='property[checkout_instructions]']", text: /llaves sobre la mesa/
    assert_select "input[name='property[initial_appliance_guides][][title]'][value='Cafetera']"
    assert_select "input[name='property[initial_recommendations][][name]'][value='Café Central']"
    assert_includes @response.body, "¿Cómo bajo a la pileta?"
    assert_includes @response.body, "Ayla leyó el archivo"
    assert_select ".bg-emerald-50", text: /Ayla leyó el archivo/
    assert_includes @response.body, "Campos completados"
    assert_includes @response.body, "nombre"
    assert_includes @response.body, "contraseña de WiFi"
    assert_includes @response.body, "electrodomésticos"
    assert_includes @response.body, "recomendaciones locales"
  end

  test "property import preview button bypasses required fields" do
    get new_property_path

    assert_response :success
    assert_select "button[name='preview_import'][formnovalidate]"
    assert_select "form[data-controller='property-import']"
    assert_select "[data-property-import-target='status']"
    assert_select "[data-property-import-target='overlay']", text: /Ayla está leyendo el archivo/
  end

  test "property import preview shows inline error" do
    AI::PropertyImportService.stub(:call, ->(**) { raise AI::PropertyImportService::ImportError, "No pude leer este archivo." }) do
      post properties_path, params: {
        preview_import: "1",
        property: {
          name: ""
        },
        property_import: {
          file: uploaded_text_file
        }
      }
    end

    assert_response :unprocessable_content
    assert_includes @response.body, "No pude leer este archivo."
    assert_select ".bg-rose-50", text: /No pude leer este archivo/
  end

  test "previews property import on edit without updating until saved" do
    result = AI::PropertyImportService::Result.new(
      property_attributes: {
        "wifi_name" => "Pippa",
        "wifi_password" => "Pippa123",
      },
      appliance_guides: [
        {
          "title" => "Lavarropas",
          "content" => "Usá fichas y el programa rápido."
        }
      ],
      faqs: [
        {
          "question" => "¿Cómo uso el lavarropas?",
          "answer" => "Usá fichas y el programa rápido.",
          "category" => "appliances"
        }
      ],
      recommendations: [],
      source_summary: "Datos extraídos del archivo."
    )

    AI::PropertyImportService.stub(:call, result) do
      patch property_path(@property), params: {
        preview_import: "1",
        property: {
          name: @property.name
        },
        property_import: {
          file: uploaded_text_file
        }
      }
    end

    assert_response :unprocessable_content
    assert_select "input[name='property[wifi_name]'][value='Pippa']"
    assert_select "input[name='property[initial_appliance_guides][][title]'][value='Lavarropas']"
    assert_includes @response.body, "FAQs"
    assert_includes @response.body, "¿Cómo uso el lavarropas?"
    assert_nil @property.reload.wifi_name

    assert_difference -> { @property.faqs.count }, 1 do
      patch property_path(@property), params: {
        property: {
          name: @property.name,
          wifi_name: "Pippa",
          wifi_password: "Pippa123",
          initial_faqs: [
            {
              question: "¿Cómo uso el lavarropas?",
              answer: "Usá fichas y el programa rápido.",
              category: "appliances"
            }
          ]
        }
      }
    end

    assert_redirected_to property_path(@property)
    assert_equal "Pippa", @property.reload.wifi_name
    assert_equal "¿Cómo uso el lavarropas?", @property.faqs.order(:created_at).last.question
  end

  private

  def sign_in_as(user)
    post login_path, params: { email: user.email, password: "password123" }
    assert_redirected_to dashboard_path
  end

  def uploaded_text_file
    file = Tempfile.new(["property-import", ".txt"])
    file.write("WiFi Pippa. Password Pippa123.")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "property.txt")
  end
end
