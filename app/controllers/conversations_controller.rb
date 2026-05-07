class ConversationsController < ApplicationController
  def index
    @conversations = Conversation.joins(:property)
      .where(properties: { account_id: current_account.id })
      .includes(:guest, :property)
      .recent
  end

  def show
    @conversation = Conversation.joins(:property)
      .where(properties: { account_id: current_account.id })
      .includes(:guest, :property, :alerts, messages: [])
      .find(params[:id])
    @messages = @conversation.messages.order(:created_at)
    @alerts = @conversation.alerts.order(created_at: :desc)
  end
end
