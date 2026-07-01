module Internal
  module AI
    class ToolsController < ActionController::API
      before_action :authenticate_ai_service!
      before_action :set_conversation

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
        @conversation = Conversation.includes(:guest, :property).find(params[:conversation_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "conversation_not_found" }, status: :not_found
      end

      def registry
        @registry ||= ::AI::SourceRegistry.new(conversation: @conversation)
      end
    end
  end
end
