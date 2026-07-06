class ConversationsController < ApplicationController
  def index
    @conversations = scoped_conversations
      .includes(:guest, :property)
      .recent
  end

  def show
    set_conversation
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
    @messages = @conversation.messages.order(:created_at, :id)
    @alerts = @conversation.alerts.order(created_at: :desc)
  end

  def reply_params
    params.require(:reply).permit(:body)
  end
end
