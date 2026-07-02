class SettingsController < ApplicationController
  PasswordUpdateError = Class.new(StandardError)

  def show
    @account = current_account
    @user = current_user
  end

  def update
    @account = current_account
    @user = current_user

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

  private

  def account_params
    params.require(:account).permit(:ai_active, :owner_whatsapp_number, :owner_whatsapp_escalations_enabled)
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
end
