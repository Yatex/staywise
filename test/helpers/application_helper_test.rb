require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  ENUM_VALUES = {
    Account => %i[AI_RESPONSE_STYLES AI_CHANNELS AI_LANGUAGES],
    Alert => %i[TYPES STATUSES],
    CheckoutEvent => %i[STATUSES],
    Conversation => %i[STATUSES CHANNELS],
    ConversationObserverActivity => %i[DIRECTIONS],
    Faq => %i[STATUSES SOURCE_TYPES],
    KnowledgeBlock => %i[CATEGORIES STATUSES],
    Message => %i[SENDERS CHANNELS],
    OperationalError => %i[SEVERITIES],
    OwnerTask => %i[KINDS CATEGORIES STATUSES],
    Property => %i[STATUSES],
    PropertySensitiveDatum => %i[KINDS],
    Recommendation => %i[CATEGORIES],
    Subscription => %i[PLANS STATUSES],
    User => %i[ROLES]
  }.flat_map do |model, constants|
    constants.flat_map { |constant| Array(model.const_get(constant)) }
  end.map(&:to_s).uniq.freeze

  test "local datetime renders in app timezone instead of utc" do
    utc_time = Time.utc(2026, 7, 1, 12, 35)

    assert_equal "America/Montevideo", Time.zone.tzinfo.name
    I18n.with_locale(:es) do
      assert_equal "01/07/2026 09:35", local_datetime(utc_time)
    end
  end

  test "every visible enum has Spanish and English translations" do
    %i[es en].each do |locale|
      missing = ENUM_VALUES.reject { |value| I18n.exists?("enums.#{value}", locale) }

      assert_empty missing, "Missing #{locale} enum translations: #{missing.join(", ")}"
    end
  end

  test "FAQ statuses and sources render translated labels" do
    I18n.with_locale(:es) do
      assert_equal "Aprobada", enum_label("approved")
      assert_equal "Pendiente de revisión", enum_label("pending_review")
      assert_equal "Respuesta del propietario", enum_label("owner_answer")
      assert_equal "Importada por IA", enum_label("ai_import")
    end
  end
end
