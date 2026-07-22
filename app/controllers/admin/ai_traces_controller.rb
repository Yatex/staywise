module Admin
  class AITracesController < BaseController
    PER_PAGE = 25
    TOOL_FILTERS = %w[
      guest_context
      stay_facts
      property_brain
      sensitive_access_info
      search_property_knowledge
      approved_recommendations
      access_instructions
      property_policy
      escalation_draft
    ].freeze

    before_action :set_trace, only: :show

    def index
      scope = AIDecisionLog.includes(:property, :message).recent
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
      @traces = scope
        .select(
          :id,
          :property_id,
          :conversation_id,
          :message_id,
          :route,
          :decision,
          :language,
          :final_outcome,
          :provider_delivery_status,
          :created_at,
          Arel.sql(<<~SQL.squish),
            COALESCE(
              ARRAY(
                SELECT DISTINCT COALESCE(tool ->> 'tool_name', tool ->> 'toolName')
                FROM jsonb_array_elements(COALESCE(ai_decision_logs.tool_calls, '[]'::jsonb)) AS tool
                WHERE COALESCE(tool ->> 'tool_name', tool ->> 'toolName') IS NOT NULL
              ),
              ARRAY[]::text[]
            ) AS tool_names
          SQL
          Arel.sql("jsonb_array_length(COALESCE(ai_decision_logs.evidence_ids, '[]'::jsonb)) AS evidence_count"),
          Arel.sql(<<~SQL.squish),
            (
              COALESCE(ai_decision_logs.fallback_reason, '') <> ''
              OR COALESCE(ai_decision_logs.route, '') LIKE '%fallback%'
              OR COALESCE(ai_decision_logs.safety_flags, '[]'::jsonb) ? 'fallback'
            ) AS fallback_summary
          SQL
          Arel.sql(<<~SQL.squish)
            (
              ai_decision_logs.validation_results ->> 'failed' = 'true'
              OR ai_decision_logs.validator_result IN ('rejected', 'contract_validation_failed')
              OR ai_decision_logs.validation_results ->> 'status' IN (
                'rejected',
                'contract_validation_failed',
                'evidence_provenance_rejected',
                'authorization_rejected',
                'security_rejected'
              )
            ) AS validation_failed_summary
          SQL
        )
        .limit(PER_PAGE)
        .offset((@current_page - 1) * PER_PAGE)
      @properties = Property.order(:name).select(:id, :name, :internal_nickname)
      @decisions = AIDecisionLog.distinct.order(:decision).pluck(:decision).compact
      @tools = TOOL_FILTERS
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
