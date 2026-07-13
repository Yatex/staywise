module Whatsapp
  class InboundMessageParser
    PUBLIC_TOKEN_PATTERN = /(?:Ayla|Staywise)\s+(?:stay|property|ref)\s+([A-Za-z0-9]{16,})/i
    ParsedMessage = Struct.new(:from, :to, :body, :property_token, :interactive_action_id, :metadata, keyword_init: true)

    def initialize(params)
      @params = params
    end

    def call
      body = value("Body", "body", "message").to_s.strip

      ParsedMessage.new(
        from: normalized_phone(value("From", "from", "phone_number")),
        to: normalized_phone(value("To", "to")),
        body: body,
        property_token: value("PropertyToken", "property_token") || body[PUBLIC_TOKEN_PATTERN, 1],
        interactive_action_id: value("ButtonPayload", "button_payload", "ListId", "list_id"),
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
