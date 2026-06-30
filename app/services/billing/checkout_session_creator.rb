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
      return { error: "Plan desconocido." } unless Subscription::PLANS.include?(@plan)
      return { error: "STRIPE_SECRET_KEY no está configurada." } if stripe_secret.blank?
      return { error: "#{price_envs.to_sentence} no está configurada." } if price_id.blank?

      response = post_to_stripe
      body = JSON.parse(response.body) rescue {}

      if response.is_a?(Net::HTTPSuccess)
        { url: body["url"] }
      else
        ErrorReporter.report(
          source: "stripe_checkout",
          severity: "error",
          account: @account,
          message: body.dig("error", "message") || "Stripe checkout failed with status #{response.code}",
          context: stripe_context.merge(status: response.code, response_body: response.body.to_s.first(1_000))
        )
        { error: body.dig("error", "message") || "No se pudo iniciar Checkout de Stripe." }
      end
    rescue StandardError => error
      Rails.logger.error("[stripe-checkout] #{error.class}: #{error.message}")
      ErrorReporter.report(error, source: "stripe_checkout", severity: "critical", account: @account, context: stripe_context)
      { error: "No se pudo iniciar Checkout de Stripe." }
    end

    private

    def post_to_stripe
      uri = URI(STRIPE_ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(stripe_secret, "")
      request.set_form_data(stripe_params)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
    end

    def stripe_params
      params = {
        "mode" => "subscription",
        "success_url" => @success_url,
        "cancel_url" => @cancel_url,
        "client_reference_id" => @account.id,
        "metadata[account_id]" => @account.id,
        "metadata[plan]" => @plan,
        "subscription_data[metadata][account_id]" => @account.id,
        "subscription_data[metadata][plan]" => @plan,
        "line_items[0][price]" => price_id,
        "line_items[0][quantity]" => 1,
        "allow_promotion_codes" => true
      }

      if stripe_customer_id.present?
        params["customer"] = stripe_customer_id
      else
        params["customer_email"] = @account.users.order(:created_at).first&.email
      end

      params
    end

    def stripe_secret
      ENV["STRIPE_SECRET_KEY"]
    end

    def price_env
      Plans.price_env_for(@plan)
    end

    def price_envs
      Plans.price_envs_for(@plan)
    end

    def price_id
      Plans.price_id_for(@plan)
    end

    def stripe_customer_id
      @account.active_subscription&.stripe_customer_id
    end

    def stripe_context
      {
        account_id: @account.id,
        plan: @plan,
        price_envs: price_envs,
        stripe_customer_id: stripe_customer_id
      }.compact
    end
  end
end
