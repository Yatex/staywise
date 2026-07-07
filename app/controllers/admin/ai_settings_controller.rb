module Admin
  class AISettingsController < BaseController
    def show
      @account = current_account
      @approved_cases = approved_cases
    end

    def update
      @account = current_account

      if @account.update(ai_settings_params)
        redirect_to admin_ai_settings_path, notice: "Configuración de IA actualizada."
      else
        @approved_cases = approved_cases
        render :show, status: :unprocessable_entity
      end
    end

    private

    def ai_settings_params
      params.require(:account).permit(
        :ai_high_score_threshold,
        :ai_medium_score_threshold,
        :ai_safety_score_threshold,
        :ai_max_clarification_attempts
      )
    end

    def approved_cases
      AIDecisionLog
        .includes(:account, :property, :conversation, :original_message, :message)
        .where(validator_result: "accepted")
        .where(final_outcome: "reply")
        .recent
        .limit(20)
    end
  end
end
