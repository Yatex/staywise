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

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          ErrorReporter.report(
            source: "twilio_provider",
            severity: "error",
            message: "Twilio message delivery failed with status #{response.code}",
            context: delivery_context(to: to, body: body).merge(status: response.code, response_body: response.body.to_s.first(1_000))
          )
          return false
        end

        true
      rescue StandardError => error
        Rails.logger.error("[twilio-provider] #{error.class}: #{error.message}")
        ErrorReporter.report(error, source: "twilio_provider", severity: "critical", context: delivery_context(to: to, body: body))
        false
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

      def delivery_context(to:, body:)
        {
          to: to,
          from: from_number,
          body_preview: body.to_s.first(300)
        }.compact
      end
    end
  end
end
