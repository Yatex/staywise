module Webhooks
  class StripeController < ApplicationController
    skip_before_action :require_authentication
    skip_before_action :verify_authenticity_token

    def create
      result = Billing::WebhookHandler.new(
        payload: request.raw_post,
        signature: request.headers["Stripe-Signature"]
      ).call

      if result[:ok]
        render json: { ok: true }
      else
        ErrorReporter.report(
          source: "stripe_webhook",
          severity: "warning",
          message: result[:error],
          context: {
            signature_present: request.headers["Stripe-Signature"].present?,
            payload_preview: request.raw_post.to_s.first(1_000)
          }
        )
        render json: { ok: false, error: result[:error] }, status: :bad_request
      end
    rescue StandardError => error
      Rails.logger.error("[stripe-webhook] #{error.class}: #{error.message}")
      ErrorReporter.report(
        error,
        source: "stripe_webhook",
        severity: "critical",
        context: {
          signature_present: request.headers["Stripe-Signature"].present?,
          payload_preview: request.raw_post.to_s.first(1_000)
        }
      )
      render json: { ok: false, error: "No se pudo procesar el webhook." }, status: :internal_server_error
    end
  end
end
