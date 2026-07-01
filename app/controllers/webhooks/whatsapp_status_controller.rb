module Webhooks
  class WhatsappStatusController < ApplicationController
    skip_before_action :require_authentication
    skip_before_action :verify_authenticity_token

    FAILURE_STATUSES = %w[failed undelivered].freeze

    def create
      return head :unauthorized unless valid_twilio_request?

      message = Message.where("metadata ->> 'provider_message_id' = ?", params[:MessageSid].to_s).first
      update_message_status(message) if message.present?
      report_delivery_failure(message) if message.present? && params[:MessageStatus].to_s.in?(FAILURE_STATUSES)

      render json: { ok: true }
    rescue StandardError => error
      Rails.logger.error("[whatsapp-status-webhook] #{error.class}: #{error.message}")
      ErrorReporter.report(error, source: "twilio_provider", severity: "critical", context: status_context)
      render json: { ok: false, error: "No se pudo procesar el estado de WhatsApp." }, status: :internal_server_error
    end

    private

    def update_message_status(message)
      metadata = message.metadata.merge(
        "delivery_status" => params[:MessageStatus],
        "delivery_error_code" => params[:ErrorCode],
        "delivery_error_message" => params[:ErrorMessage],
        "delivery_status_updated_at" => Time.current.iso8601
      ).compact

      message.update!(metadata: metadata)
    end

    def report_delivery_failure(message)
      ErrorReporter.report(
        source: "twilio_provider",
        severity: "error",
        message: "Twilio WhatsApp delivery #{params[:MessageStatus]}",
        account: message.conversation.property.account,
        property: message.conversation.property,
        context: status_context.merge(message_id: message.id, conversation_id: message.conversation_id)
      )
    end

    def valid_twilio_request?
      Whatsapp::TwilioRequestValidator.valid?(
        url: request.original_url,
        params: request.request_parameters,
        signature: request.headers["X-Twilio-Signature"]
      )
    end

    def status_context
      {
        message_sid: params[:MessageSid],
        message_status: params[:MessageStatus],
        error_code: params[:ErrorCode],
        error_message: params[:ErrorMessage],
        to: params[:To],
        from: params[:From],
        url: request.original_url
      }.compact
    end
  end
end
