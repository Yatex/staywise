class DashboardController < ApplicationController
  def index
    alert_scope = Alert.joins(:property).where(properties: { account_id: current_account.id })

    @guest_requests = current_account.guest_requests.includes(:guest, :property, :conversation).open.pending_first.limit(5)
    @alerts = alert_scope.includes(:guest, :property).open.order(created_at: :desc).limit(5)
  end
end
