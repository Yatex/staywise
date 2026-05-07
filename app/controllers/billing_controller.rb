class BillingController < ApplicationController
  def show
    @subscription = current_account.active_subscription
    @plans = Billing::Plans.all
  end

  def pricing
    @plans = Billing::Plans.all
    render :show
  end

  def checkout
    result = Billing::CheckoutSessionCreator.new(
      account: current_account,
      plan: params[:plan],
      success_url: subscription_url,
      cancel_url: subscription_url
    ).call

    if result[:url].present?
      redirect_to result[:url], allow_other_host: true
    else
      redirect_to subscription_path, alert: result[:error] || "Stripe checkout is not configured yet."
    end
  end

  def portal
    result = Billing::PortalSessionCreator.new(
      account: current_account,
      return_url: subscription_url
    ).call

    if result[:url].present?
      redirect_to result[:url], allow_other_host: true
    else
      redirect_to subscription_path, alert: result[:error] || "Subscription portal is not configured yet."
    end
  end
end
