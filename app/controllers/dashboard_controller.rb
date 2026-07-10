class DashboardController < ApplicationController
  def index
    conversation_scope = Conversation.joins(:property).where(properties: { account_id: current_account.id })
    alert_scope = Alert.joins(:property).where(properties: { account_id: current_account.id })

    @recent_conversations = conversation_scope.includes(:guest, :property).recent.limit(8).to_a
    @today_conversations, @older_conversations = @recent_conversations.partition do |conversation|
      (conversation.last_message_at || conversation.updated_at).in_time_zone.today?
    end
    @alerts = alert_scope.includes(:guest, :property).open.order(created_at: :desc).limit(5)
    @guest_requests = current_account.guest_requests.includes(:guest, :property, :conversation).open.pending_first.limit(5)
  end
end
