class CopilotThreadsController < ApplicationController
  before_action :set_thread, only: :show

  def index
    @threads = current_user.copilot_threads.includes(:property, :copilot_messages).recent.limit(50)
  end

  def new
    @properties = current_account.properties.active.order(:name)
    @selected_property_id = params[:property_id]
  end

  def create
    property = current_account.properties.active.find(params.require(:property_id))
    thread = current_user.copilot_threads.create!(account: current_account, property: property)
    result = Copilot::DraftService.call(
      thread: thread,
      content: params.require(:guest_message),
      host_context: params[:host_context]
    )
    if result.success?
      redirect_to copilot_thread_path(thread), notice: "Ayla preparó una respuesta para revisar."
    else
      redirect_to copilot_thread_path(thread), alert: copilot_error_message(result)
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to new_copilot_thread_path, alert: "La propiedad no pertenece a tu cuenta."
  rescue ActionController::ParameterMissing, ArgumentError => error
    redirect_to new_copilot_thread_path, alert: error.message
  end

  def show
    @messages = @thread.copilot_messages.order(:created_at, :id)
    @latest_run = @thread.copilot_runs.order(created_at: :desc).first
  end

  private

  def set_thread
    @thread = current_user.copilot_threads.includes(:property).find(params[:id])
  end

  def copilot_error_message(result)
    case result.run&.error_type
    when "ai_timeout" then "Ayla tardó demasiado en responder. Intentá nuevamente."
    when "malformed_response" then "Ayla devolvió una respuesta inválida. Intentá nuevamente."
    else "No pudimos preparar la respuesta en este momento."
    end
  end
end
