require "net/http"

module Whatsapp
  module Providers
    class TwilioProvider < BaseProvider
      TWILIO_MESSAGES_URL = "https://api.twilio.com/2010-04-01/Accounts/%<sid>s/Messages.json".freeze

      def send_message(to:, body:)
        return false unless configured?

        uri = URI(format(TWILIO_MESSAGES_URL, sid: account_sid))
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(account_sid, auth_token)
        request.set_form_data(
          "From" => formatted(from_number),
          "To" => formatted(to),
          "Body" => body
        )

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        response.is_a?(Net::HTTPSuccess)
      end

      private

      def configured?
        account_sid.present? && auth_token.present? && from_number.present?
      end

      def account_sid
        ENV["TWILIO_ACCOUNT_SID"]
      end

      def auth_token
        ENV["TWILIO_AUTH_TOKEN"]
      end

      def from_number
        ENV["TWILIO_WHATSAPP_FROM"]
      end

      def formatted(number)
        number.to_s.start_with?("whatsapp:") ? number : "whatsapp:#{number}"
      end
    end
  end
end
