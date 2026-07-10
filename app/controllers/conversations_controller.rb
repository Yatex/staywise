class ConversationsController < ApplicationController
  PER_PAGE = 30

  def index
    @current_page = [params[:page].to_i, 1].max
    scope = scoped_conversations
      .includes(:guest, :property)
      .recent
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @conversations = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE).to_a
    @message_counts = Message.where(conversation_id: @conversations.map(&:id)).group(:conversation_id).count
  end

  def show
    set_conversation
  end

  def refresh
    set_conversation
    render partial: "refresh", locals: { conversation: @conversation, messages: @messages, alerts: @alerts, guest_requests: @guest_requests }
  end

  def reply
    set_conversation
    result = Whatsapp::OwnerReplySender.call(
      conversation: @conversation,
      user: current_user,
      body: reply_params[:body]
    )

    if result.success?
      redirect_to conversation_path(@conversation, anchor: "message-#{result.message.id}"), notice: "Mensaje enviado al huésped por WhatsApp desde Ayla."
    else
      target = result.message.present? ? conversation_path(@conversation, anchor: "message-#{result.message.id}") : conversation_path(@conversation)
      redirect_to target, alert: result.error
    end
  end

  private

  def scoped_conversations
    Conversation.joins(:property).where(properties: { account_id: current_account.id })
  end

  def set_conversation
    @conversation = scoped_conversations
      .includes(:guest, :property, :alerts, messages: [])
      .find(params[:id])
    @messages = complete_message_history_for(@conversation)
    @alerts = @conversation.alerts.order(created_at: :desc)
    @guest_requests = @conversation.guest_requests.order(created_at: :desc)
    @guest_request_message_ids = @guest_requests.pluck(:message_id).compact
  end

  def reply_params
    params.require(:reply).permit(:body)
  end

  def complete_message_history_for(conversation)
    direct_messages = conversation.messages.to_a
    traced_message_ids = AIDecisionLog
      .where(conversation: conversation)
      .pluck(:message_id, :original_message_id)
      .flatten
      .compact
      .uniq

    traced_messages = Message
      .joins(conversation: :property)
      .where(id: traced_message_ids, properties: { account_id: current_account.id })
      .to_a

    (direct_messages + traced_messages)
      .uniq(&:id)
      .sort_by { |message| [message.created_at, message.id] }
  end
end
