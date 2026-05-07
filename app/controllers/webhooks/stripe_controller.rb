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
        render json: { ok: false, error: result[:error] }, status: :bad_request
      end
    end
  end
end
