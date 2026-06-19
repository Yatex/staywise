class AIConfigurationsController < ApplicationController
  def show
    @account = current_account
    @recent_ai_responses = Message.joins(conversation: :property)
      .where(sender: "ai", properties: { account_id: current_account.id })
      .order(created_at: :desc)
      .limit(8)
    @open_ai_alerts = Alert.joins(:property)
      .where(properties: { account_id: current_account.id })
      .open
      .order(created_at: :desc)
      .limit(8)
  end

  def update
    @account = current_account

    if @account.update(ai_configuration_params)
      redirect_to ai_configuration_path, notice: "Configuración de IA actualizada."
    else
      show
      render :show, status: :unprocessable_entity
    end
  end

  private

  def ai_configuration_params
    permitted = params.require(:account).permit(
      :ai_active,
      :ai_goal,
      :ai_tone,
      :ai_response_style,
      :ai_preferred_language,
      :ai_default_channel,
      :default_ai_instructions,
      :unsure_behavior,
      :late_checkout_policy,
      :emergency_contact_behavior,
      ai_escalation_rules: Alert::TYPES,
      ai_automation_settings: Account::DEFAULT_AUTOMATION_SETTINGS.keys
    )

    normalize_json_booleans(permitted, :ai_escalation_rules)
    normalize_json_booleans(permitted, :ai_automation_settings)
    permitted
  end

  def normalize_json_booleans(permitted, key)
    return if permitted[key].blank?

    permitted[key] = permitted[key].to_h.transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) }
  end
end
