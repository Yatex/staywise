class ConversationsController < ApplicationController
  PER_PAGE = 30

  def index
    @current_page = [params[:page].to_i, 1].max
    scope = scoped_conversations
      .includes(:guest, :property)
      .recent
    if params[:filter] == "unread" && observer_for_current_user.present?
      scope = scope.where(id: observer_for_current_user.conversation_observer_activities.unseen.select(:conversation_id))
    end
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @conversations = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE).to_a
    conversation_ids = @conversations.map(&:id)
    @message_counts = readable_messages.where(conversation_id: conversation_ids).group(:conversation_id).count
    latest_property_ids = readable_messages
      .where(conversation_id: conversation_ids)
      .order(created_at: :desc, id: :desc)
      .pluck(:conversation_id, :property_id)
      .each_with_object({}) { |(conversation_id, property_id), memo| memo[conversation_id] ||= property_id }
    @conversation_display_properties = Property.where(id: latest_property_ids.values.compact.uniq).index_by(&:id)
    @conversation_display_property_ids = latest_property_ids
    @observer_activities = observer_activities_for(conversation_ids).index_by(&:conversation_id)
    @last_ai_responses = readable_messages.where(conversation_id: conversation_ids, sender: "ai")
      .group(:conversation_id).maximum(:created_at)
  end

  def show
    set_conversation
    mark_observer_activity_seen!
  end

  def refresh
    set_conversation
    mark_observer_activity_seen!
    render partial: "refresh", locals: { conversation: @conversation, messages: @messages, alerts: @alerts, guest_requests: @guest_requests }
  end

  def reply
    @conversation = account_scoped_conversations.find(params[:id])
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
    return Conversation.all if current_user.admin?

    account_scoped_conversations
  end

  def account_scoped_conversations
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
    @alerts = readable_alerts_for(@conversation).order(created_at: :desc)
    @guest_requests = readable_guest_requests_for(@conversation).order(created_at: :desc)
    @guest_request_message_ids = @guest_requests.pluck(:message_id).compact
    @can_reply = account_scoped_conversations.where(id: @conversation.id).exists?
  end

  def reply_params
    params.require(:reply).permit(:body)
  end

  def complete_message_history_for(conversation)
    direct_messages = readable_messages.where(conversation: conversation).to_a
    traced_message_ids = readable_ai_decision_logs
      .where(conversation: conversation)
      .pluck(:message_id, :original_message_id)
      .flatten
      .compact
      .uniq

    traced_messages = Message
      .where(id: traced_message_ids)
      .merge(readable_messages)
      .to_a

    (direct_messages + traced_messages)
      .uniq(&:id)
      .sort_by { |message| [message.created_at, message.id] }
  end

  def display_property_for(conversation)
    return conversation.property if current_user.admin?
    return conversation.property if conversation.property.account_id == current_account.id

    Property.find_by(id: conversation.messages.where(account_id: current_account.id).order(created_at: :desc, id: :desc).pick(:property_id))
  end

  def readable_messages
    current_user.admin? ? Message.all : Message.where(account_id: current_account.id)
  end

  def readable_ai_decision_logs
    current_user.admin? ? AIDecisionLog.all : AIDecisionLog.where(account_id: current_account.id)
  end

  def readable_alerts_for(conversation)
    return conversation.alerts if current_user.admin?

    conversation.alerts.joins(:property).where(properties: { account_id: current_account.id })
  end

  def readable_guest_requests_for(conversation)
    return conversation.guest_requests if current_user.admin?

    conversation.guest_requests.where(account_id: current_account.id)
  end

  def observer_for_current_user
    return unless current_user.owner? || current_user.admin?

    current_account
  end

  def observer_activities_for(conversation_ids)
    return ConversationObserverActivity.none if observer_for_current_user.blank?

    observer_for_current_user.conversation_observer_activities.where(conversation_id: conversation_ids)
  end

  def mark_observer_activity_seen!
    activity = observer_activities_for([@conversation.id]).find_by(conversation_id: @conversation.id)
    activity&.mark_seen! if activity&.observer_seen_at.nil? || activity&.unread_activity_count.to_i.positive?
  end
end
