class ConversationsController < ApplicationController
  PER_PAGE = 20
  MESSAGE_PAGE_SIZE = 20
  REFRESH_LIMIT = 50

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
    load_initial_messages
    load_conversation_sidebar
    mark_observer_activity_seen!
  end

  def refresh
    set_conversation
    @messages = messages_after(params[:after_message_id]).limit(REFRESH_LIMIT).to_a
    return head :no_content if @messages.empty?

    @guest_request_message_ids = visible_guest_request_message_ids(@messages)
    render partial: "message_rows", locals: { messages: @messages, guest_request_message_ids: @guest_request_message_ids }
  end

  def older_messages
    set_conversation
    @messages, @has_older_messages = message_page_before(
      created_at: params[:before_created_at],
      id: params[:before_id]
    )
    @guest_request_message_ids = visible_guest_request_message_ids(@messages)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to conversation_path(@conversation) }
    end
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
      .includes(:guest, :property)
      .find(params[:id])
    @display_property = display_property_for(@conversation)
    @can_reply = account_scoped_conversations.where(id: @conversation.id).exists?
    set_sentry_tags(
      conversation_id: @conversation.id,
      property_id: @display_property&.id || @conversation.property_id
    )
  end

  def reply_params
    params.require(:reply).permit(:body)
  end

  def load_initial_messages
    @messages, @has_older_messages = message_page_before
    @guest_request_message_ids = visible_guest_request_message_ids(@messages)
  end

  def load_conversation_sidebar
    @alerts = readable_alerts_for(@conversation).order(created_at: :desc, id: :desc).limit(25)
    @guest_requests = readable_guest_requests_for(@conversation).order(created_at: :desc, id: :desc).limit(25)
  end

  def message_page_before(created_at: nil, id: nil)
    scope = readable_messages.where(conversation_id: @conversation.id)
    if created_at.present? && id.present?
      cursor_time = Time.zone.parse(created_at.to_s)
      scope = scope.where(
        "messages.created_at < :created_at OR (messages.created_at = :created_at AND messages.id < :id)",
        created_at: cursor_time,
        id: id.to_i
      )
    end

    rows = scope.order(created_at: :desc, id: :desc).limit(MESSAGE_PAGE_SIZE + 1).to_a
    [rows.first(MESSAGE_PAGE_SIZE).reverse, rows.size > MESSAGE_PAGE_SIZE]
  rescue ArgumentError
    [[], false]
  end

  def messages_after(message_id)
    return Message.none if message_id.blank?

    if message_id.to_i.zero?
      return readable_messages
        .where(conversation_id: @conversation.id)
        .order(created_at: :asc, id: :asc)
    end

    cursor = readable_messages.where(conversation_id: @conversation.id, id: message_id).pick(:created_at, :id)
    return Message.none if cursor.blank?

    readable_messages
      .where(conversation_id: @conversation.id)
      .where(
        "messages.created_at > :created_at OR (messages.created_at = :created_at AND messages.id > :id)",
        created_at: cursor.first,
        id: cursor.last
      )
      .order(created_at: :asc, id: :asc)
  end

  def visible_guest_request_message_ids(messages)
    readable_guest_requests_for(@conversation)
      .where(message_id: messages.map(&:id))
      .pluck(:message_id)
      .compact
  end

  def display_property_for(conversation)
    return conversation.property if current_user.admin?
    return conversation.property if conversation.property.account_id == current_account.id

    Property.find_by(id: conversation.messages.where(account_id: current_account.id).order(created_at: :desc, id: :desc).pick(:property_id))
  end

  def readable_messages
    current_user.admin? ? Message.all : Message.where(account_id: current_account.id)
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
