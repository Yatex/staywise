module Internal
  module AI
    class CopilotToolsController < ActionController::API
      before_action :authenticate_ai_service!
      before_action :set_context

      def property_brain
        render json: registry.property_brain(
          guest_message: params[:guest_message],
          conversation_summary: params[:conversation_summary],
          limit: params.fetch(:limit, 8).to_i.clamp(1, 20)
        )
      end

      def sensitive_access_info
        render json: sensitive_registry.sensitive_access_info(guest_message: params[:guest_message])
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
        render json: sensitive_registry.access_instructions
      end

      def property_policy
        render json: registry.property_policy(params[:policy_type])
      end

      private

      def authenticate_ai_service!
        expected = ENV["AI_SERVICE_TOKEN"].to_s
        return if expected.blank?

        scheme, received = request.authorization.to_s.split(" ", 2)
        valid = scheme == "Bearer" && received.present? && received.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(received, expected)
        head :unauthorized unless valid
      end

      def set_context
        resolved = ::Copilot::ToolContext.resolve(params.require(:decision_context_id))
        @thread = resolved.fetch(:thread)
        @message = resolved.fetch(:message)
      rescue ::Copilot::ToolContext::InvalidContext, ActionController::ParameterMissing
        render json: { error: "invalid_copilot_context" }, status: :unauthorized
      end

      def registry
        @registry ||= ::AI::SourceRegistry.new(
          property: @thread.property,
          guest_message: @message.content,
          sensitive_access_authorized: false
        )
      end

      def sensitive_registry
        @sensitive_registry ||= ::AI::SourceRegistry.new(
          property: @thread.property,
          guest_message: @message.content,
          sensitive_access_authorized: true
        )
      end
    end
  end
end
