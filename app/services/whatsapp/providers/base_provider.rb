module Whatsapp
  module Providers
    class BaseProvider
      DeliveryResult = Struct.new(:success?, :provider_message_id, :provider_status, :error, :raw_response, keyword_init: true)

      def send_message(to:, body:, media_urls: [])
        raise NotImplementedError
      end

      def send_template(to:, template_sid:, variables: {})
        raise NotImplementedError
      end

      def send_interactive(to:, content_key:, variables: {}, fallback_body:)
        raise NotImplementedError
      end
    end
  end
end
