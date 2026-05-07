module Whatsapp
  module Providers
    class NullProvider < BaseProvider
      def send_message(to:, body:)
        Rails.logger.info("[whatsapp-null] to=#{to} body=#{body}")
        true
      end
    end
  end
end
