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

      response.is_a?(Net::HTTPSuccess)
    end

    private

    def configured?
      ENV["RESEND_API_KEY"].present? && ENV["RESEND_FROM_EMAIL"].present?
    end
  end
end
