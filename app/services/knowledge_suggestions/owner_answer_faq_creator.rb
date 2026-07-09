module KnowledgeSuggestions
  class OwnerAnswerFaqCreator
    def self.call(alert:, owner_answer:, owner_message:)
      new(alert: alert, owner_answer: owner_answer, owner_message: owner_message).call
    end

    def initialize(alert:, owner_answer:, owner_message:)
      @alert = alert
      @owner_answer = owner_answer.to_s.strip
      @owner_message = owner_message
    end

    def call
      return if @alert.blank? || @owner_answer.blank?

      question = original_question
      return if question.blank?
      return if duplicate_question?(question)

      suggestion = @alert.property.faqs.create!(
        question: question,
        answer: @owner_answer,
        category: @alert.alert_type.presence || "owner_answer",
        active: false,
        status: "pending_review",
        source_type: "owner_answer",
        source_alert: @alert,
        source_message: @owner_message,
        metadata: {
          "source_type" => "owner_answer",
          "status" => "pending_review",
          "property_id" => @alert.property_id,
          "conversation_id" => @alert.conversation_id,
          "guest_id" => @alert.guest_id,
          "original_message_id" => @alert.original_message_id,
          "owner_message_id" => @owner_message&.id,
          "ai_decision_log_id" => @alert.ai_decision_log_id
        }.compact
      )

      append_trace_learning_event(suggestion)
      suggestion
    end

    private

    def original_question
      @alert.description.presence ||
        @alert.original_message&.body.presence ||
        @alert.conversation&.messages&.where(sender: "guest")&.order(created_at: :desc)&.first&.body.to_s.strip.presence
    end

    def duplicate_question?(question)
      @alert.property.faqs.where("lower(question) = ?", question.downcase).exists?
    end

    def append_trace_learning_event(suggestion)
      return if @alert.ai_decision_log.blank?

      payload = @alert.ai_decision_log.payload.to_h
      @alert.ai_decision_log.update!(
        payload: payload.merge(
          "knowledge_suggestion" => {
            "created" => true,
            "faq_id" => suggestion.id,
            "source_type" => suggestion.source_type,
            "status" => suggestion.status,
            "property_id" => suggestion.property_id,
            "question" => suggestion.question
          }
        )
      )
    rescue StandardError => error
      Rails.logger.warn("[owner-alert-learning] trace_update_failed #{error.class}: #{error.message}")
    end
  end
end
