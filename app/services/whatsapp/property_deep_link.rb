module Whatsapp
  class PropertyDeepLink
    def self.call(property)
      new(property).call
    end

    def initialize(property)
      @property = property
    end

    def call
      return nil if whatsapp_number.blank?

      "https://wa.me/#{whatsapp_number}?text=#{ERB::Util.url_encode(message_text)}"
    end

    def message_text
      "Hola, tengo una consulta sobre #{@property.display_name}. #{@property.whatsapp_reference}"
    end

    private

    def whatsapp_number
      raw_number = ENV["TWILIO_WHATSAPP_FROM"].presence || ENV["WHATSAPP_FROM_NUMBER"].presence
      return if raw_number.blank?

      raw_number.to_s.gsub(/\Awhatsapp:/, "").gsub(/[^\d]/, "")
    end
  end
end
