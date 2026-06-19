module Admin
  class BaseController < ApplicationController
    before_action :require_admin!

    private

    def require_admin!
      return if current_user&.admin_like?

      redirect_to dashboard_path, alert: "Solo los administradores pueden acceder a esa sección."
    end
  end
end
