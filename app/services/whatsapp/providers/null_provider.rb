module Whatsapp
  module Providers
    class NullProvider < BaseProvider
      def send_message(to:, body:, media_urls: [])
        Rails.logger.info("[whatsapp-null] to=#{to} body=#{body} media_urls=#{media_urls.inspect}")
        true
      end

      def send_template(to:, template_sid:, variables: {})
        Rails.logger.info("[whatsapp-null-template] to=#{to} template_sid=#{template_sid} variables=#{variables.inspect}")
        true
      end
    end
  end
end
