module Admin
  class BaseController < ApplicationController
    before_action :require_admin!

    private

    def require_admin!
      return if current_user&.admin_like?

      redirect_to dashboard_path, alert: "Only admins can access that section."
    end
  end
end
