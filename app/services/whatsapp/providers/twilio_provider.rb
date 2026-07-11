require "net/http"

module Whatsapp
  module Providers
    class TwilioProvider < BaseProvider
      TWILIO_MESSAGES_URL = "https://api.twilio.com/2010-04-01/Accounts/%<sid>s/Messages.json".freeze

      def send_message(to:, body:, media_urls: [])
        return false unless configured?

        payload = { "Body" => body, "MediaUrls" => Array(media_urls).compact_blank }
        deliver(to: to, payload: payload, context: { body: body })
      end

      def send_template(to:, template_sid:, variables: {})
        return false unless configured?
        return send_message(to: to, body: variables.values.compact.join(" ")) if template_sid.blank?

        deliver(
          to: to,
          payload: {
            "ContentSid" => template_sid,
            "ContentVariables" => variables.compact.to_json
          },
          context: { body: "template:#{template_sid}" }
        )
      end

      private

      def deliver(to:, payload:, context:)
        uri = URI(format(TWILIO_MESSAGES_URL, sid: account_sid))
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(account_sid, auth_token)
        media_urls = Array(payload.delete("MediaUrls"))
        payload = payload.merge(
          "From" => formatted(from_number),
          "To" => formatted(to),
        )
        payload["StatusCallback"] = status_callback_url if status_callback_url.present?
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(payload.to_a + media_urls.map { |url| ["MediaUrl", url] })

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          ErrorReporter.report(
            source: "twilio_provider",
            severity: "error",
            message: "Twilio message delivery failed with status #{response.code}",
            context: delivery_context(to: to, body: context[:body]).merge(status: response.code, response_body: response.body.to_s.first(1_000))
          )
          return DeliveryResult.new(success?: false, error: "Twilio message delivery failed with status #{response.code}", raw_response: response.body.to_s.first(1_000))
        end

        body_json = JSON.parse(response.body)
        DeliveryResult.new(
          success?: true,
          provider_message_id: body_json["sid"],
          provider_status: body_json["status"],
          raw_response: body_json.slice("sid", "status", "to", "from", "error_code", "error_message")
        )
      rescue StandardError => error
        Rails.logger.error("[twilio-provider] #{error.class}: #{error.message}")
        ErrorReporter.report(error, source: "twilio_provider", severity: "critical", context: delivery_context(to: to, body: context[:body]))
        DeliveryResult.new(success?: false, error: error.message)
      end

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

      def status_callback_url
        app_host = ENV["APP_HOST"].to_s.delete_suffix("/")
        return if app_host.blank?

        "#{app_host}/webhooks/whatsapp_status"
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
