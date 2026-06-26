module Webhooks
  class WhatsappController < ApplicationController
    skip_before_action :require_authentication
    skip_before_action :verify_authenticity_token

    def create
      return head :unauthorized unless valid_twilio_request?

      result = Whatsapp::IncomingMessageHandler.new(params.to_unsafe_h).call
      response = { ok: true, conversation_id: result[:conversation]&.id, replied: result[:replied] }
      response[:error] = result[:error] if result[:error].present?
      render json: response
    rescue StandardError => error
      Rails.logger.error("[whatsapp-webhook] #{error.class}: #{error.message}")
      render json: { ok: false, error: "No se pudo procesar el webhook." }, status: :internal_server_error
    end

    private

    def valid_twilio_request?
      Whatsapp::TwilioRequestValidator.valid?(
        url: request.original_url,
        params: request.request_parameters,
        signature: request.headers["X-Twilio-Signature"]
      )
    end
  end
end
