module Whatsapp
  class ProviderStatus
    def self.configured?
      new.configured?
    end

    def self.label
      configured? ? "Proveedor activo" : "Proveedor no conectado"
    end

    def configured?
      provider == "twilio" && twilio_configured?
    end

    private

    def provider
      ENV.fetch("WHATSAPP_PROVIDER", "null")
    end

    def twilio_configured?
      ENV["TWILIO_ACCOUNT_SID"].present? &&
        ENV["TWILIO_AUTH_TOKEN"].present? &&
        ENV["TWILIO_WHATSAPP_FROM"].present?
    end
  end
end
