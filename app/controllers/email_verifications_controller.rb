class EmailVerificationsController < ApplicationController
  skip_before_action :require_authentication

  def show
    user = User.find_by(email_verification_token: params[:token].to_s)

    if user.blank?
      redirect_to login_path, alert: "El link de confirmación no es válido."
      return
    end

    user.verify_email!
    redirect_to login_path, notice: "Email confirmado. Ya podés ingresar."
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)

    if user&.email_verification_required?
      Notifications::EmailVerificationNotifier.call(user)
    end

    redirect_to login_path, notice: "Si el email existe y falta confirmar, te enviamos un nuevo link."
  end
end
