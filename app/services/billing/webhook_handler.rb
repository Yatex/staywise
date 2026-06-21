require "json"
require "openssl"

module Billing
  class WebhookHandler
    SIGNATURE_TOLERANCE = 5.minutes

    def initialize(payload:, signature:)
      @payload = payload
      @signature = signature
    end

    def call
      return { ok: false, error: "Invalid Stripe signature." } unless valid_signature?

      event = JSON.parse(@payload)
      account = account_for_event(event)

      BillingEvent.find_or_create_by!(stripe_event_id: event.fetch("id")) do |billing_event|
        billing_event.account = account
        billing_event.event_type = event.fetch("type")
        billing_event.payload = event
      end

      sync_subscription(account, event) if account
      { ok: true }
    rescue JSON::ParserError
      { ok: false, error: "Invalid JSON payload." }
    rescue ActiveRecord::RecordInvalid => error
      { ok: false, error: error.record.errors.full_messages.to_sentence }
    end

    private

    def valid_signature?
      secret = ENV["STRIPE_WEBHOOK_SECRET"]
      return false if secret.blank?
      return false if @signature.blank?

      timestamp = @signature[/t=(\d+)/, 1]
      signatures = @signature.scan(/v1=([a-f0-9]+)/).flatten
      return false if timestamp.blank? || signatures.blank?
      return false if signature_expired?(timestamp)

      signed_payload = "#{timestamp}.#{@payload}"
      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, signed_payload)
      signatures.any? { |signature| ActiveSupport::SecurityUtils.secure_compare(signature, expected) }
    end

    def account_for_event(event)
      object = event.dig("data", "object") || {}
      account_id = object.dig("metadata", "account_id") || object["client_reference_id"]
      Account.find_by(id: account_id) || Account.joins(:subscriptions).find_by(subscriptions: { stripe_customer_id: object["customer"] })
    end

    def sync_subscription(account, event)
      object = event.dig("data", "object") || {}
      event_type = event.fetch("type")
      return unless event_type.in?(%w[checkout.session.completed customer.subscription.updated customer.subscription.deleted])

      subscription = subscription_record(account, object, event_type)
      subscription.plan = plan_for(object) || subscription.plan || "starter"
      subscription.status = normalized_status(object["status"], event_type)
      subscription.stripe_customer_id = object["customer"] if object["customer"].present?
      subscription.stripe_subscription_id = stripe_subscription_id(object, event_type) if stripe_subscription_id(object, event_type).present?
      subscription.current_period_end = Time.at(object["current_period_end"]) if object["current_period_end"].present?
      subscription.save!
    end

    def subscription_record(account, object, event_type)
      stripe_subscription_id = stripe_subscription_id(object, event_type)
      if stripe_subscription_id.present?
        existing = account.subscriptions.find_by(stripe_subscription_id: stripe_subscription_id)
        return existing if existing
      end

      account.subscriptions.order(created_at: :desc).first_or_initialize
    end

    def plan_for(object)
      object.dig("metadata", "plan").presence || Plans.plan_for_price_id(price_id_for(object))
    end

    def price_id_for(object)
      object.dig("items", "data", 0, "price", "id") ||
        object.dig("lines", "data", 0, "price", "id")
    end

    def stripe_subscription_id(object, event_type)
      return object["subscription"] if event_type == "checkout.session.completed"

      object["id"]
    end

    def signature_expired?(timestamp)
      signed_at = Time.at(timestamp.to_i)
      signed_at < SIGNATURE_TOLERANCE.ago || signed_at > SIGNATURE_TOLERANCE.from_now
    end

    def normalized_status(status, event_type)
      return "canceled" if event_type == "customer.subscription.deleted"

      Subscription::STATUSES.include?(status.to_s) ? status : "active"
    end
  end
end
