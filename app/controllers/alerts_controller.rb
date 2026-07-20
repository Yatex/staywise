class AlertsController < ApplicationController
  PER_PAGE = 25

  def index
    scope = Alert.joins(:property)
      .where(properties: { account_id: current_account.id })
      .includes(:guest, :property, :conversation, :original_message)
      .order(created_at: :desc)
    @current_page = [params[:page].to_i, 1].max
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @alerts = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE)
  end

  def show
    @alert = scoped_alerts.includes(:guest, :property, :conversation, :original_message).find(params[:id])
    @guest_message = @alert.original_message || guest_message_before_alert(@alert)
  end

  def update
    @alert = scoped_alerts.find(params[:id])

    if @alert.update(alert_params)
      redirect_to alerts_path, notice: "Alerta actualizada."
    else
      render :show, status: :unprocessable_entity
    end
  end

  def answer_question
    @alert = scoped_alerts.unknown_questions.open.includes(:property).find(params[:id])
    faq = @alert.property.faqs.create!(question: answer_question_params[:question], answer: answer_question_params[:answer], category: "custom_notes", active: true)
    @alert.update!(status: "resolved", ai_suggested_action: "Respondida y guardada como FAQ ##{faq.id}.")

    redirect_to property_path(@alert.property, anchor: "new-questions"), notice: "Duda guardada como FAQ. La IA podrá usar esta respuesta la próxima vez."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to property_path(@alert.property, anchor: "new-questions"), alert: error.record.errors.full_messages.to_sentence
  end

  private

  def scoped_alerts
    Alert.joins(:property).where(properties: { account_id: current_account.id })
  end

  def guest_message_before_alert(alert)
    return if alert.conversation.blank?

    alert.conversation.messages
      .where(sender: "guest")
      .where("created_at <= ?", alert.created_at)
      .order(created_at: :desc, id: :desc)
      .first
  end

  def alert_params
    params.require(:alert).permit(:status)
  end

  def answer_question_params
    params.require(:faq).permit(:question, :answer)
  end
end
