class DashboardController < ApplicationController
  def index
    conversation_scope = Conversation.joins(:property).where(properties: { account_id: current_account.id })
    alert_scope = Alert.joins(:property).where(properties: { account_id: current_account.id })

    @recent_conversations = conversation_scope.includes(:guest, :property).recent.limit(5)
    @alerts = alert_scope.operational.includes(:guest, :property).open.order(created_at: :desc).limit(5)
  end
end
