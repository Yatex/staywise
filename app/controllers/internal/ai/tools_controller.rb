module Internal
  module AI
    class ToolsController < ActionController::API
      before_action :authenticate_ai_service!
      before_action :set_conversation

      def property_brain
        render json: registry.property_brain(
          guest_message: params[:guest_message],
          conversation_summary: params[:conversation_summary],
          limit: params.fetch(:limit, 8).to_i.clamp(1, 20)
        )
      end

      def sensitive_access_info
        render json: registry.sensitive_access_info(
          guest_message: params[:guest_message]
        )
      end

      def guest_context
        render json: registry.guest_context(query: params[:query])
      end

      def stay_facts
        render json: registry.stay_facts(params[:requested_fields])
      end

      def search_property_knowledge
        render json: registry.search_property_knowledge(
          query: params[:query],
          topic: params[:topic],
          limit: params.fetch(:limit, 5).to_i.clamp(1, 10)
        )
      end

      def approved_recommendations
        render json: registry.approved_recommendations(
          category: params[:category],
          limit: params.fetch(:limit, 5).to_i.clamp(1, 10)
        )
      end

      def access_instructions
        render json: registry.access_instructions
      end

      def property_policy
        render json: registry.property_policy(params[:policy_type])
      end

      def escalation_draft
        render json: {
          draft: true,
          category: params[:category],
          urgency: params[:urgency],
          summary: params[:summary]
        }
      end

      private

      def authenticate_ai_service!
        expected = ENV["AI_SERVICE_TOKEN"].to_s
        return if expected.blank?

        head :unauthorized unless request.authorization == "Bearer #{expected}"
      end

      def set_conversation
        resolved = ::AI::DecisionContext.resolve(params.require(:decision_context_id))
        @conversation = resolved.fetch(:conversation)
        @guest_message = resolved.fetch(:guest_message)
      rescue ::AI::DecisionContext::InvalidContext, ActionController::ParameterMissing
        render json: { error: "invalid_decision_context" }, status: :unauthorized
      end

      def registry
        @registry ||= ::AI::SourceRegistry.new(conversation: @conversation, guest_message: @guest_message)
      end
    end
  end
end
