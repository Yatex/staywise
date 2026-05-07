require "net/http"

module Billing
  class CheckoutSessionCreator
    STRIPE_ENDPOINT = "https://api.stripe.com/v1/checkout/sessions".freeze

    def initialize(account:, plan:, success_url:, cancel_url:)
      @account = account
      @plan = plan.to_s
      @success_url = success_url
      @cancel_url = cancel_url
    end

    def call
      return { error: "Unknown plan." } unless Subscription::PLANS.include?(@plan)
      return { error: "STRIPE_SECRET_KEY is not configured." } if stripe_secret.blank?
      return { error: "#{price_env} is not configured." } if price_id.blank?

      response = post_to_stripe
      body = JSON.parse(response.body) rescue {}

      if response.is_a?(Net::HTTPSuccess)
        { url: body["url"] }
      else
        { error: body.dig("error", "message") || "Stripe checkout failed." }
      end
    end

    private

    def post_to_stripe
      uri = URI(STRIPE_ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(stripe_secret, "")
      request.set_form_data(stripe_params)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    end

    def stripe_params
      {
        "mode" => "subscription",
        "success_url" => @success_url,
        "cancel_url" => @cancel_url,
        "customer_email" => @account.users.order(:created_at).first&.email,
        "client_reference_id" => @account.id,
        "metadata[account_id]" => @account.id,
        "metadata[plan]" => @plan,
        "line_items[0][price]" => price_id,
        "line_items[0][quantity]" => 1,
        "allow_promotion_codes" => true
      }
    end

    def stripe_secret
      ENV["STRIPE_SECRET_KEY"]
    end

    def price_env
      Plans.price_env_for(@plan)
    end

    def price_id
      ENV[price_env]
    end
  end
end
