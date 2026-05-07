module Whatsapp
  class InboundMessageParser
    ParsedMessage = Struct.new(:from, :to, :body, :property_id, :metadata, keyword_init: true)

    def initialize(params)
      @params = params
    end

    def call
      body = value("Body", "body", "message").to_s.strip

      ParsedMessage.new(
        from: normalized_phone(value("From", "from", "phone_number")),
        to: normalized_phone(value("To", "to")),
        body: body,
        property_id: value("PropertyId", "property_id") || body[/Staywise property #(\d+)/i, 1],
        metadata: @params.except("controller", "action")
      )
    end

    private

    def value(*keys)
      keys.lazy.map { |key| @params[key] || @params[key.to_sym] }.find(&:present?)
    end

    def normalized_phone(phone)
      phone.to_s.gsub(/\Awhatsapp:/, "").strip
    end
  end
end
