class AlertsController < ApplicationController
  def index
    @alerts = Alert.joins(:property)
      .where(properties: { account_id: current_account.id })
      .includes(:guest, :property, :conversation)
      .order(created_at: :desc)
  end

  def show
    @alert = scoped_alerts.includes(:guest, :property, :conversation).find(params[:id])
  end

  def update
    @alert = scoped_alerts.find(params[:id])

    if @alert.update(alert_params)
      redirect_to alerts_path, notice: "Alerta actualizada."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def scoped_alerts
    Alert.joins(:property).where(properties: { account_id: current_account.id })
  end

  def alert_params
    params.require(:alert).permit(:status, :priority)
  end
end
