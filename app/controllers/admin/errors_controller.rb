module Admin
  class ErrorsController < BaseController
    PER_PAGE = 25

    before_action :set_error, only: [:show, :resolve]

    def index
      scope = OperationalError.includes(:account, :property).recent
      scope = scope.where(source: params[:source]) if params[:source].present?
      scope = scope.where(severity: params[:severity]) if params[:severity].present?
      scope = filter_by_status(scope)
      scope = search(scope) if params[:q].present?

      @current_page = [params[:page].to_i, 1].max
      @total_count = scope.count
      @total_pages = (@total_count.to_f / PER_PAGE).ceil
      @errors = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE)
      @sources = OperationalError.distinct.order(:source).pluck(:source)
      @open_count = OperationalError.open.count
      @critical_count = OperationalError.open.where(severity: "critical").count
    end

    def show
    end

    def resolve
      @error.update!(resolved_at: Time.current)
      redirect_to admin_errors_path(query_params), notice: "Error marcado como resuelto."
    end

    private

    def set_error
      @error = OperationalError.includes(:account, :property).find(params[:id])
    end

    def filter_by_status(scope)
      case params[:status]
      when "all"
        scope
      when "resolved"
        scope.resolved
      else
        scope.open
      end
    end

    def search(scope)
      query = "%#{OperationalError.sanitize_sql_like(params[:q].strip)}%"
      scope.where(
        "operational_errors.message ILIKE :query OR operational_errors.error_class ILIKE :query OR operational_errors.source ILIKE :query",
        query: query
      )
    end

    def query_params
      params.permit(:q, :source, :severity, :status, :page).to_h.compact_blank
    end
  end
end
