class DashboardController < ApplicationController
  def index
    property_scope = current_account.properties
    conversation_scope = Conversation.joins(:property).where(properties: { account_id: current_account.id })
    alert_scope = Alert.joins(:property).where(properties: { account_id: current_account.id })

    @total_properties = property_scope.count
    @active_conversations = conversation_scope.where(status: "active").count
    @open_alerts = alert_scope.open.count
    @unanswered_questions = alert_scope.where(alert_type: "unknown_question").open.count
    @recent_ai_responses = Message.joins(conversation: :property)
      .where(sender: "ai", properties: { account_id: current_account.id })
      .order(created_at: :desc)
      .limit(5)

    @recent_conversations = conversation_scope.includes(:guest, :property).recent.limit(5)
    @alerts = alert_scope.includes(:guest, :property).open.order(created_at: :desc).limit(5)
    @properties = property_scope.includes(:knowledge_blocks, :recommendations, :faqs).order(:name).limit(6)
    @subscription = current_account.active_subscription
  end
end
