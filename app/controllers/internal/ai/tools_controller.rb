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

        authorization = request.authorization.to_s
        scheme, received = authorization.split(" ", 2)
        token_match = secure_token_match?(received, expected)
        return if scheme == "Bearer" && token_match

        Rails.logger.warn(
          "[ai-tools-auth] #{auth_failure_context(
            authorization: authorization,
            scheme: scheme,
            received: received,
            expected: expected,
            token_match: token_match
          ).to_json}"
        )
        head :unauthorized
      end

      def secure_token_match?(received, expected)
        return false if received.blank? || expected.blank?
        return false unless received.bytesize == expected.bytesize

        ActiveSupport::SecurityUtils.secure_compare(received, expected)
      end

      def auth_failure_context(authorization:, scheme:, received:, expected:, token_match:)
        {
          auth_header_present: authorization.present?,
          auth_scheme: scheme.presence,
          received_token_present: received.present?,
          expected_token_present: expected.present?,
          token_length_matches: received.present? && received.bytesize == expected.bytesize,
          token_match: token_match,
          env_var_name_used: "AI_SERVICE_TOKEN",
          path: request.path,
          received_token_has_surrounding_whitespace: surrounding_whitespace?(received),
          expected_token_has_surrounding_whitespace: surrounding_whitespace?(expected),
          received_token_wrapped_in_quotes: wrapped_in_quotes?(received),
          expected_token_wrapped_in_quotes: wrapped_in_quotes?(expected)
        }
      end

      def surrounding_whitespace?(value)
        value.present? && value != value.strip
      end

      def wrapped_in_quotes?(value)
        value.present? && ((value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'")))
      end

      def set_conversation
        resolved = ::AI::DecisionContext.resolve(params.require(:decision_context_id))
        @conversation = resolved.fetch(:conversation)
        @guest_message = resolved.fetch(:guest_message)
        if defined?(Sentry) && Sentry.initialized?
          Sentry.configure_scope do |scope|
            scope.set_tags(
              request_id: request.request_id,
              account_id: @conversation.property.account_id,
              property_id: @conversation.property_id,
              conversation_id: @conversation.id,
              tool_name: action_name
            )
          end
        end
      rescue ::AI::DecisionContext::InvalidContext, ActionController::ParameterMissing
        render json: { error: "invalid_decision_context" }, status: :unauthorized
      end

      def registry
        @registry ||= ::AI::SourceRegistry.new(conversation: @conversation, guest_message: @guest_message)
      end
    end
  end
end
