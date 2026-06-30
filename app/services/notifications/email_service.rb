require "net/http"
require "json"

module Notifications
  class EmailService
    RESEND_ENDPOINT = "https://api.resend.com/emails".freeze

    def self.deliver(to:, subject:, html:)
      new.deliver(to: to, subject: subject, html: html)
    end

    def deliver(to:, subject:, html:)
      return false unless configured?

      uri = URI(RESEND_ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{ENV["RESEND_API_KEY"]}"
      request["Content-Type"] = "application/json"
      request.body = {
        from: ENV["RESEND_FROM_EMAIL"],
        to: [to],
        subject: subject,
        html: html
      }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        ErrorReporter.report(
          source: "email_service",
          severity: "error",
          message: "Email delivery failed with status #{response.code}",
          context: delivery_context(to: to, subject: subject).merge(status: response.code, response_body: response.body.to_s.first(1_000))
        )
        return false
      end

      true
    rescue StandardError => error
      Rails.logger.error("[email-service] #{error.class}: #{error.message}")
      ErrorReporter.report(error, source: "email_service", severity: "critical", context: delivery_context(to: to, subject: subject))
      false
    end

    private

    def configured?
      ENV["RESEND_API_KEY"].present? && ENV["RESEND_FROM_EMAIL"].present?
    end

    def delivery_context(to:, subject:)
      {
        to: to,
        subject: subject,
        from: ENV["RESEND_FROM_EMAIL"]
      }.compact
    end
  end
end
