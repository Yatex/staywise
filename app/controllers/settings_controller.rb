class SettingsController < ApplicationController
  def show
    @account = current_account
    @user = current_user
  end

  def update
    @account = current_account
    @user = current_user

    Account.transaction do
      @account.update!(account_params)
      @user.update!(user_params) if params[:user].present?
    end

    redirect_to settings_path, notice: "Configuración actualizada."
  rescue ActiveRecord::RecordInvalid => error
    @settings_error = error.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  end

  private

  def account_params
    params.require(:account).permit(
      :name,
      :default_ai_instructions,
      :ai_tone,
      :languages_supported,
      :unsure_behavior,
      :late_checkout_policy,
      :emergency_contact_behavior,
      :whatsapp_enabled,
      :email_alerts_enabled,
      :ai_active,
      :ai_goal,
      :ai_response_style,
      :ai_preferred_language,
      :ai_default_channel
    )
  end

  def user_params
    params.require(:user).permit(:name, :email)
  end
end
