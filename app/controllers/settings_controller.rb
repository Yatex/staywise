class SettingsController < ApplicationController
  PasswordUpdateError = Class.new(StandardError)

  def show
    @account = current_account
    @user = current_user
  end

  def update
    @account = current_account
    @user = current_user
    return head :forbidden if observer_preference_submitted? && !observer_preference_authorized?

    Account.transaction do
      @account.update!(account_params) if params[:account].present?
      update_user! if params[:user].present?
    end

    redirect_to settings_path, notice: "Configuración actualizada."
  rescue ActiveRecord::RecordInvalid => error
    @settings_error = error.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  rescue PasswordUpdateError => error
    @settings_error = error.message
    render :show, status: :unprocessable_entity
  end

  def update_co_host_observer_mode
    return head :forbidden unless observer_preference_authorized?

    co_host = current_account.co_hosts.find(params[:id])
    co_host.update!(observer_mode_enabled: ActiveModel::Type::Boolean.new.cast(params[:observer_mode_enabled]))
    redirect_to settings_path, notice: "Modo observador del co-host actualizado."
  end

  private

  def account_params
    params.require(:account).permit(:ai_active, :owner_whatsapp_number, :owner_whatsapp_escalations_enabled, :observer_mode_enabled)
  end

  def update_user!
    permitted = params.require(:user).permit(:name, :current_password, :password, :password_confirmation)
    @user.name = permitted[:name] if permitted.key?(:name)

    if password_change_requested?(permitted)
      raise PasswordUpdateError, "La contraseña actual no es correcta." unless @user.authenticate(permitted[:current_password].to_s)
      raise PasswordUpdateError, "Ingresá una nueva contraseña." if permitted[:password].blank?

      @user.password = permitted[:password]
      @user.password_confirmation = permitted[:password_confirmation]
    end

    @user.save!
  end

  def password_change_requested?(permitted)
    permitted.values_at(:current_password, :password, :password_confirmation).any?(&:present?)
  end

  def observer_preference_submitted?
    params[:account].respond_to?(:key?) && params[:account].key?(:observer_mode_enabled)
  end

  def observer_preference_authorized?
    current_user.owner? || current_user.admin?
  end
end
