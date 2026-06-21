require "base64"
require "openssl"

module Whatsapp
  class TwilioRequestValidator
    def self.valid?(url:, params:, signature:)
      new(url: url, params: params, signature: signature).valid?
    end

    def initialize(url:, params:, signature:)
      @url = url.to_s
      @params = params.to_h
      @signature = signature.to_s
    end

    def valid?
      return true unless twilio_provider?
      return false if auth_token.blank? || @signature.blank?

      expected_signature = Base64.strict_encode64(
        OpenSSL::HMAC.digest("sha1", auth_token, signature_payload)
      )

      ActiveSupport::SecurityUtils.secure_compare(expected_signature, @signature)
    rescue StandardError => error
      Rails.logger.warn("[whatsapp-webhook] Twilio signature validation failed: #{error.class}: #{error.message}")
      false
    end

    private

    def signature_payload
      sorted_params = @params
        .except("controller", "action")
        .sort_by { |key, _value| key.to_s }
        .map { |key, value| "#{key}#{Array(value).join}" }
        .join

      "#{@url}#{sorted_params}"
    end

    def twilio_provider?
      ENV.fetch("WHATSAPP_PROVIDER", "null") == "twilio"
    end

    def auth_token
      ENV["TWILIO_AUTH_TOKEN"]
    end
  end
end
