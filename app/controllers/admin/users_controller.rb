module Admin
  class UsersController < BaseController
    PER_PAGE = 25

    before_action :set_user, only: [:extend_subscription, :update_role, :update_property_limit]

    def index
      scope = User.includes(account: :subscriptions).order(created_at: :desc)
      scope = scope.where("users.email ILIKE :query OR users.name ILIKE :query", query: "%#{User.sanitize_sql_like(params[:q].strip)}%") if params[:q].present?
      scope = scope.where(role: params[:role]) if params[:role].present?
      scope = scope.joins(account: :subscriptions).where(subscriptions: { plan: params[:plan] }) if params[:plan].present?
      scope = scope.joins(account: :subscriptions).where(subscriptions: { status: params[:status] }) if params[:status].present?

      @current_page = [params[:page].to_i, 1].max
      @total_count = scope.distinct.count
      @total_pages = (@total_count.to_f / PER_PAGE).ceil
      @users = scope.distinct.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE)
    end

    def update_role
      new_role = params[:role].to_s

      if @user.id == current_user.id && new_role != "admin"
        redirect_to admin_users_path(query_params), alert: "No podés quitar tu propio rol de administrador."
        return
      end

      unless User::ROLES.include?(new_role)
        redirect_to admin_users_path(query_params), alert: "Elegí un rol válido."
        return
      end

      if @user.update(role: new_role)
        redirect_to admin_users_path(query_params), notice: "Rol actualizado para #{@user.email}."
      else
        redirect_to admin_users_path(query_params), alert: @user.errors.full_messages.to_sentence
      end
    end

    def extend_subscription
      plan = params[:plan].to_s
      end_date = parse_end_date(params[:end_date])

      unless Subscription::PLANS.include?(plan) && end_date.present?
        redirect_to admin_users_path(query_params), alert: "Elegí un plan y una fecha final válida."
        return
      end

      subscription = @user.account.active_subscription || @user.account.subscriptions.build
      subscription.assign_attributes(
        plan: plan,
        status: "active",
        current_period_end: end_date.end_of_day,
        trial_ends_at: nil
      )
      subscription.save!

      redirect_to admin_users_path(query_params), notice: "Plan de #{@user.email} extendido hasta #{end_date.to_fs(:long)}."
    rescue ActiveRecord::RecordInvalid => error
      redirect_to admin_users_path(query_params), alert: error.record.errors.full_messages.to_sentence
    end

    def update_property_limit
      raw_value = params[:property_limit_override].to_s.strip
      unless raw_value.blank? || raw_value.match?(/\A\d+\z/)
        redirect_to admin_users_path(query_params), alert: "El límite especial debe ser un número entero igual o mayor a 0."
        return
      end

      account = @user.account
      previous_value = account.property_limit_override
      account.update!(property_limit_override: raw_value.presence)
      Rails.logger.info(
        "[admin-property-limit-override] " \
        "admin_user_id=#{current_user.id} account_id=#{account.id} " \
        "previous=#{previous_value.inspect} new=#{account.property_limit_override.inspect}"
      )

      redirect_to admin_users_path(query_params), notice: "Límite especial actualizado para #{account.name}."
    rescue ActiveRecord::RecordInvalid => error
      redirect_to admin_users_path(query_params), alert: error.record.errors.full_messages.to_sentence
    end

    private

    def set_user
      @user = User.includes(account: :subscriptions).find(params[:id])
    end

    def parse_end_date(value)
      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def query_params
      params.permit(:q, :page).to_h.compact_blank
    end
  end
end
