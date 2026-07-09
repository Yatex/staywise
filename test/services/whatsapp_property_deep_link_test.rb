require "test_helper"
require "cgi"

class WhatsappPropertyDeepLinkTest < ActiveSupport::TestCase
  setup do
    @previous_twilio_from = ENV["TWILIO_WHATSAPP_FROM"]
    @previous_whatsapp_from = ENV["WHATSAPP_FROM_NUMBER"]
    @account = Account.create!(name: "Deep Link Stays")
    @property = @account.properties.create!(name: "Beach Loft")
  end

  teardown do
    ENV["TWILIO_WHATSAPP_FROM"] = @previous_twilio_from
    ENV["WHATSAPP_FROM_NUMBER"] = @previous_whatsapp_from
  end

  test "does not generate a fake whatsapp link without a configured sender" do
    ENV["TWILIO_WHATSAPP_FROM"] = nil
    ENV["WHATSAPP_FROM_NUMBER"] = nil

    assert_nil Whatsapp::PropertyDeepLink.call(@property)
  end

  test "generates a property-specific whatsapp link from configured sender" do
    ENV["TWILIO_WHATSAPP_FROM"] = "whatsapp:+59899999999"

    link = Whatsapp::PropertyDeepLink.call(@property)

    assert_includes link, "https://wa.me/59899999999"
    assert_includes CGI.unescape(link), @property.whatsapp_reference
    assert_not_includes CGI.unescape(link), "Hola, tengo una consulta"
  end
end
