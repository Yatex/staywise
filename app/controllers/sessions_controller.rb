class SessionsController < ApplicationController
  skip_before_action :require_authentication

  def new
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)

    if user&.authenticate(params[:password])
      sign_in(user)
      redirect_to dashboard_path, notice: "Sesión iniciada."
    else
      flash.now[:alert] = "El email o la contraseña son incorrectos."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    sign_out
    redirect_to login_path, notice: "Sesión cerrada."
  end
end
