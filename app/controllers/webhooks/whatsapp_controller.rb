module Webhooks
  class WhatsappController < ApplicationController
    skip_before_action :require_authentication
    skip_before_action :verify_authenticity_token

    def create
      unless valid_twilio_request?
        ErrorReporter.report(
          source: "whatsapp_webhook",
          severity: "warning",
          message: "Invalid Twilio webhook signature",
          context: webhook_context.merge(signature_present: request.headers["X-Twilio-Signature"].present?)
        )
        return head :unauthorized
      end

      result = Whatsapp::CopilotInboundRouter.new(params.to_unsafe_h).call
      response = {
        ok: true,
        conversation_id: result[:conversation]&.id,
        copilot_thread_id: result[:copilot_thread]&.id,
        replied: result[:replied]
      }
      response[:error] = result[:error] if result[:error].present?
      response[:ignored] = true if result[:ignored]
      response[:duplicate] = true if result[:duplicate]
      response[:channel] = result[:channel] if result[:channel].present?
      render json: response
    rescue StandardError => error
      Rails.logger.error("[whatsapp-webhook] #{error.class}: #{error.message}")
      ErrorReporter.report(error, source: "whatsapp_webhook", severity: "critical", context: webhook_context)
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

    def webhook_context
      {
        from: params[:From],
        to: params[:To],
        body: params[:Body],
        message_sid: params[:MessageSid] || params[:SmsMessageSid],
        message_type: params[:MessageType],
        num_media: params[:NumMedia],
        media_content_type: params[:MediaContentType0],
        interactive_action_present: params[:ButtonPayload].present? || params[:ListId].present?,
        location_present: params[:Latitude].present? || params[:Longitude].present?,
        provider: ENV.fetch("WHATSAPP_PROVIDER", "null"),
        url: request.original_url
      }.compact
    end
  end
end
