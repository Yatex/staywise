module Webhooks
  class WhatsappController < ApplicationController
    skip_before_action :require_authentication
    skip_before_action :verify_authenticity_token

    def create
      result = Whatsapp::IncomingMessageHandler.new(params.to_unsafe_h).call
      render json: { ok: true, conversation_id: result[:conversation]&.id, replied: result[:replied] }
    rescue Whatsapp::IncomingMessageHandler::MissingAccount
      render json: { ok: false, error: "No Staywise account is configured for WhatsApp." }, status: :unprocessable_entity
    rescue StandardError => error
      Rails.logger.error("[whatsapp-webhook] #{error.class}: #{error.message}")
      render json: { ok: false, error: "Webhook could not be processed." }, status: :internal_server_error
    end
  end
end
