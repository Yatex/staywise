require "net/http"

module Whatsapp
  class HostCopilotQrCode
    QR_ENDPOINT = "https://api.qrserver.com/v1/create-qr-code/".freeze

    def self.svg
      new.svg
    end

    def initialize
      @deep_link = HostCopilotDeepLink.call
    end

    def svg
      remote_svg.presence || fallback_svg
    end

    private

    def remote_svg
      return if @deep_link.blank?

      uri = URI(QR_ENDPOINT)
      uri.query = URI.encode_www_form(size: "512x512", format: "svg", data: @deep_link)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 1.5, read_timeout: 2.5) do |http|
        http.get(uri.request_uri)
      end
      response.body if response.is_a?(Net::HTTPSuccess)
    rescue StandardError => error
      Rails.logger.warn("[host-copilot-qr] fallback used: #{error.class}: #{error.message}")
      nil
    end

    def fallback_svg
      link = ERB::Util.html_escape(@deep_link || "WhatsApp no configurado")
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img" aria-label="Abrir Ayla en WhatsApp">
          <rect width="512" height="512" rx="28" fill="#f8fafc"/>
          <rect x="40" y="40" width="432" height="432" rx="20" fill="#ffffff" stroke="#cbd5e1"/>
          <text x="256" y="220" text-anchor="middle" font-family="Arial, sans-serif" font-size="34" font-weight="700" fill="#0f172a">Ayla</text>
          <text x="256" y="266" text-anchor="middle" font-family="Arial, sans-serif" font-size="20" fill="#475569">WhatsApp Copilot</text>
          <text x="256" y="315" text-anchor="middle" font-family="Arial, sans-serif" font-size="13" fill="#64748b">#{link}</text>
        </svg>
      SVG
    end
  end
end
