module Whatsapp
  class ProviderFactory
    def self.build
      case ENV.fetch("WHATSAPP_PROVIDER", "null")
      when "twilio"
        Providers::TwilioProvider.new
      else
        Providers::NullProvider.new
      end
    end
  end
end
