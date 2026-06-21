require "net/http"

module Billing
  class PortalSessionCreator
    STRIPE_ENDPOINT = "https://api.stripe.com/v1/billing_portal/sessions".freeze

    def initialize(account:, return_url:)
      @account = account
      @return_url = return_url
    end

    def call
      subscription = @account.active_subscription
      return { error: "Todavía no hay un cliente de Stripe asociado." } if subscription&.stripe_customer_id.blank?
      return { error: "STRIPE_SECRET_KEY no está configurada." } if stripe_secret.blank?

      response = post_to_stripe(subscription.stripe_customer_id)
      body = JSON.parse(response.body) rescue {}

      if response.is_a?(Net::HTTPSuccess)
        { url: body["url"] }
      else
        { error: body.dig("error", "message") || "No se pudo abrir el portal de Stripe." }
      end
    rescue StandardError => error
      Rails.logger.error("[stripe-portal] #{error.class}: #{error.message}")
      { error: "No se pudo abrir el portal de Stripe." }
    end

    private

    def post_to_stripe(customer_id)
      uri = URI(STRIPE_ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(stripe_secret, "")
      request.set_form_data("customer" => customer_id, "return_url" => @return_url)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
    end

    def stripe_secret
      ENV["STRIPE_SECRET_KEY"]
    end
  end
end
