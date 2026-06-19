class ApplicationController < ActionController::Base
  before_action :require_authentication

  helper_method :current_user, :current_account, :authenticated?

  private

  def current_user
    @current_user ||= User.includes(:account).find_by(id: session[:user_id]) if session[:user_id]
  end

  def current_account
    current_user&.account
  end

  def authenticated?
    current_user.present?
  end

  def require_authentication
    redirect_to login_path unless authenticated?
  end

  def sign_in(user)
    reset_session
    session[:user_id] = user.id
  end

  def sign_out
    reset_session
  end

  def ensure_property_limit!
    return if current_account.can_add_property?

    redirect_to subscription_path, alert: "Tu plan actual alcanzó el límite de propiedades."
  end
end
