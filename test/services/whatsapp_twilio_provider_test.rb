require "test_helper"

class WhatsappTwilioProviderTest < ActiveSupport::TestCase
  class InvalidRegistry
    def self.validate_variables(_template_sid, variables)
      Whatsapp::TwilioContentRegistry::VariableValidation.new(
        valid?: false,
        expected_keys: %w[1 2],
        actual_keys: variables.keys,
        error: "twilio_template_variable_mismatch"
      )
    end
  end

  setup do
    @previous_sid = ENV["TWILIO_ACCOUNT_SID"]
    @previous_token = ENV["TWILIO_AUTH_TOKEN"]
    @previous_from = ENV["TWILIO_WHATSAPP_FROM"]
    ENV["TWILIO_ACCOUNT_SID"] = "AC_TEST"
    ENV["TWILIO_AUTH_TOKEN"] = "secret"
    ENV["TWILIO_WHATSAPP_FROM"] = "+15550009999"
  end

  teardown do
    ENV["TWILIO_ACCOUNT_SID"] = @previous_sid
    ENV["TWILIO_AUTH_TOKEN"] = @previous_token
    ENV["TWILIO_WHATSAPP_FROM"] = @previous_from
  end

  test "rejects mismatched template variables before calling Twilio" do
    provider = Whatsapp::Providers::TwilioProvider.new(content_registry: InvalidRegistry)

    assert_difference -> { OperationalError.where(source: "twilio_provider").count }, 1 do
      Net::HTTP.stub(:start, ->(*) { flunk "Twilio should not be called" }) do
        result = provider.send_template(to: "+15550000001", template_sid: "HX_TEST", variables: { "1" => "Resumen" })

        assert_not result.success?
        assert_equal "twilio_template_variable_mismatch", result.error
      end
    end

    error = OperationalError.where(source: "twilio_provider").last
    assert_equal "HX_TEST", error.context["template_sid"]
    assert_equal %w[1], error.context["variable_keys"]
    assert_equal %w[1 2], error.context["expected_variable_keys"]
  end
end
