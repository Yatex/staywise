module Whatsapp
  class HostCopilotDeepLink
    DEFAULT_MESSAGE = "Hola Ayla".freeze

    def self.call(message: DEFAULT_MESSAGE)
      number = whatsapp_number
      return if number.blank?

      "https://wa.me/#{number}?text=#{ERB::Util.url_encode(message)}"
    end

    def self.display_number
      raw_number.to_s.gsub(/\Awhatsapp:/, "").presence
    end

    def self.whatsapp_number
      raw_number.to_s.gsub(/\Awhatsapp:/, "").gsub(/[^\d]/, "").presence
    end

    def self.raw_number
      ENV["TWILIO_WHATSAPP_FROM"].presence || ENV["WHATSAPP_FROM_NUMBER"].presence
    end

    private_class_method :raw_number
  end
end
