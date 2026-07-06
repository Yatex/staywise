module Admin
  class AITracesController < BaseController
    PER_PAGE = 25

    before_action :set_trace, only: :show

    def index
      scope = AIDecisionLog.includes(:account, :property, :guest, :conversation, :message).recent
      scope = scope.where(conversation_id: params[:conversation_id]) if params[:conversation_id].present?
      scope = scope.where(property_id: params[:property_id]) if params[:property_id].present?
      scope = scope.where(decision: params[:decision]) if params[:decision].present?
      scope = scope.with_fallback if params[:fallback].present?
      scope = scope.validation_failed if params[:validation_failed].present?
      scope = filter_by_tool(scope)
      scope = filter_by_date(scope)

      @current_page = [params[:page].to_i, 1].max
      @total_count = scope.count
      @total_pages = (@total_count.to_f / PER_PAGE).ceil
      @traces = scope.limit(PER_PAGE).offset((@current_page - 1) * PER_PAGE)
      @properties = Property.order(:name)
      @decisions = AIDecisionLog.distinct.order(:decision).pluck(:decision).compact
      @tools = AIDecisionLog.pluck(:tool_calls).flatten.filter_map { |tool| tool["tool_name"] || tool["toolName"] }.uniq.sort
    end

    def show
    end

    private

    def set_trace
      @trace = AIDecisionLog.includes(:account, :property, :guest, :conversation, :message).find(params[:id])
    end

    def filter_by_tool(scope)
      return scope if params[:tool].blank?

      scope.where("tool_calls::text ILIKE ?", "%#{AIDecisionLog.sanitize_sql_like(params[:tool])}%")
    end

    def filter_by_date(scope)
      scope = scope.where("ai_decision_logs.created_at >= ?", Date.parse(params[:from]).beginning_of_day) if params[:from].present?
      scope = scope.where("ai_decision_logs.created_at <= ?", Date.parse(params[:to]).end_of_day) if params[:to].present?
      scope
    rescue ArgumentError
      scope
    end

    def query_params
      params.permit(:conversation_id, :property_id, :decision, :fallback, :validation_failed, :tool, :from, :to, :page).to_h.compact_blank
    end
    helper_method :query_params
  end
end
