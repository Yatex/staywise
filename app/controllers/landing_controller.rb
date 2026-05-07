class LandingController < ApplicationController
  skip_before_action :require_authentication
  layout "marketing"

  def index
    redirect_to dashboard_path if authenticated?
  end
end
