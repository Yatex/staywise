class CopilotMessagesController < ApplicationController
  def create
    thread = current_user.copilot_threads.find(params[:copilot_thread_id])
    result = Copilot::DraftService.call(
      thread: thread,
      content: params.require(:guest_message),
      host_context: params[:host_context]
    )
    if result.success?
      redirect_to copilot_thread_path(thread), notice: "Ayla actualizó la sugerencia."
    else
      redirect_to copilot_thread_path(thread), alert: "No pudimos preparar la respuesta. Podés volver a intentarlo."
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to copilot_threads_path, alert: "No tenés acceso a esa consulta."
  rescue ActionController::ParameterMissing, ArgumentError => error
    redirect_to copilot_thread_path(thread), alert: error.message
  end
end
