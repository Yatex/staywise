require "net/http"

module Whatsapp
  class PropertyQrCode
    QR_ENDPOINT = "https://api.qrserver.com/v1/create-qr-code/".freeze

    def self.svg_for(property)
      new(property).svg
    end

    def initialize(property)
      @property = property
      @deep_link = PropertyDeepLink.call(property)
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
      return unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue StandardError => error
      Rails.logger.warn("[qr-code] fallback used: #{error.class}: #{error.message}")
      nil
    end

    def fallback_svg
      escaped_link = ERB::Util.html_escape(@deep_link || "Número de WhatsApp no configurado")
      escaped_name = ERB::Util.html_escape(@property.display_name)

      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img" aria-label="Staywise WhatsApp QR">
          <rect width="512" height="512" rx="28" fill="#f8fafc"/>
          <rect x="40" y="40" width="432" height="432" rx="20" fill="#ffffff" stroke="#cbd5e1"/>
          <text x="256" y="224" text-anchor="middle" font-family="Arial, sans-serif" font-size="28" font-weight="700" fill="#0f172a">Staywise</text>
          <text x="256" y="264" text-anchor="middle" font-family="Arial, sans-serif" font-size="18" fill="#475569">#{escaped_name}</text>
          <text x="256" y="308" text-anchor="middle" font-family="Arial, sans-serif" font-size="14" fill="#64748b">#{escaped_link}</text>
        </svg>
      SVG
    end
  end
end
