require "test_helper"

class WhatsappInboundMessageParserTest < ActiveSupport::TestCase
  test "extracts opaque property token from ayla reference" do
    token = SecureRandom.base58(24)

    parsed = Whatsapp::InboundMessageParser.new(
      "From" => "whatsapp:+15550000012",
      "To" => "whatsapp:+15550009999",
      "Body" => "Hola. Ayla stay #{token}"
    ).call

    assert_equal token, parsed.property_token
  end

  test "does not extract numeric property id reference" do
    parsed = Whatsapp::InboundMessageParser.new(
      "From" => "whatsapp:+15550000012",
      "To" => "whatsapp:+15550009999",
      "Body" => "Ayla property #7 What is the wifi?"
    ).call

    assert_nil parsed.property_token
  end
end
