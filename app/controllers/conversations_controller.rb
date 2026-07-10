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
    conversation_ids = @conversations.map(&:id)
    @message_counts = Message.where(account_id: current_account.id, conversation_id: conversation_ids).group(:conversation_id).count
    latest_property_ids = Message
      .where(account_id: current_account.id, conversation_id: conversation_ids)
      .order(created_at: :desc, id: :desc)
      .pluck(:conversation_id, :property_id)
      .each_with_object({}) { |(conversation_id, property_id), memo| memo[conversation_id] ||= property_id }
    @conversation_display_properties = Property.where(id: latest_property_ids.values.compact.uniq).index_by(&:id)
    @conversation_display_property_ids = latest_property_ids
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
    property_scoped = Conversation.where(id: Conversation.joins(:property).where(properties: { account_id: current_account.id }).select(:id))
    message_scoped = Conversation.where(id: Message.where(account_id: current_account.id).select(:conversation_id))
    property_scoped.or(message_scoped)
  end

  def set_conversation
    @conversation = scoped_conversations
      .includes(:guest, :property, :alerts, messages: [])
      .find(params[:id])
    @display_property = display_property_for(@conversation)
    @messages = complete_message_history_for(@conversation)
    @alerts = @conversation.alerts.joins(:property).where(properties: { account_id: current_account.id }).order(created_at: :desc)
    @guest_requests = @conversation.guest_requests.where(account_id: current_account.id).order(created_at: :desc)
    @guest_request_message_ids = @guest_requests.pluck(:message_id).compact
  end

  def reply_params
    params.require(:reply).permit(:body)
  end

  def complete_message_history_for(conversation)
    direct_messages = conversation.messages.where(account_id: current_account.id).to_a
    traced_message_ids = AIDecisionLog
      .where(account_id: current_account.id)
      .where(conversation: conversation)
      .pluck(:message_id, :original_message_id)
      .flatten
      .compact
      .uniq

    traced_messages = Message
      .where(id: traced_message_ids, account_id: current_account.id)
      .to_a

    (direct_messages + traced_messages)
      .uniq(&:id)
      .sort_by { |message| [message.created_at, message.id] }
  end

  def display_property_for(conversation)
    return conversation.property if conversation.property.account_id == current_account.id

    Property.find_by(id: conversation.messages.where(account_id: current_account.id).order(created_at: :desc, id: :desc).pick(:property_id))
  end
end
