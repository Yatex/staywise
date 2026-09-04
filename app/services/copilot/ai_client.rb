require "net/http"

module Copilot
  class AIClient
    CONNECT_TIMEOUT = 3
    READ_TIMEOUT = 25

    class Error < StandardError
      attr_reader :type, :response_payload

      def initialize(message, type:, response_payload: nil)
        super(message)
        @type = type
        @response_payload = response_payload
      end
    end

    def call(payload)
      raise Error.new("AI_SERVICE_URL is not configured", type: "not_configured") if ENV["AI_SERVICE_URL"].blank?

      uri = URI.join(ENV.fetch("AI_SERVICE_URL"), "/copilot")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{ENV.fetch('AI_SERVICE_TOKEN', '')}"
      request["X-Request-ID"] = payload.fetch(:correlation_id)
      request["X-Ayla-Deadline-At"] = ((Time.now.to_f + READ_TIMEOUT - 1) * 1_000).round.to_s
      request.body = payload.to_json
      response = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: CONNECT_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }
      parsed = JSON.parse(response.body)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error.new("AI service returned #{response.code}", type: "http_error", response_payload: parsed)
      end

      parsed
    rescue JSON::ParserError => error
      raise Error.new(error.message, type: "malformed_response")
    rescue Net::OpenTimeout, Net::ReadTimeout => error
      raise Error.new(error.message, type: "ai_timeout")
    rescue SocketError, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED => error
      raise Error.new(error.message, type: "network_error")
    end
  end
end
