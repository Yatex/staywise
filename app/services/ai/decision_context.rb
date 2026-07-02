module AI
  class DecisionContext
    PURPOSE = :ai_decision_context
    TTL = 10.minutes

    class InvalidContext < StandardError; end

    def self.issue(conversation:, guest_message:)
      payload = {
        account_id: conversation.property.account_id,
        property_id: conversation.property_id,
        guest_id: conversation.guest_id,
        conversation_id: conversation.id,
        message_id: guest_message.id
      }

      verifier.generate(payload, expires_in: TTL)
    end

    def self.resolve(token)
      payload = verifier.verified(token)
      raise InvalidContext, "invalid_decision_context" unless payload.is_a?(Hash)

      normalized = payload.stringify_keys
      conversation = Conversation.includes(:guest, property: :account).find(normalized.fetch("conversation_id"))
      raise InvalidContext, "decision_context_conversation_mismatch" unless conversation.property_id == normalized.fetch("property_id")
      raise InvalidContext, "decision_context_guest_mismatch" unless conversation.guest_id == normalized.fetch("guest_id")
      raise InvalidContext, "decision_context_account_mismatch" unless conversation.property.account_id == normalized.fetch("account_id")
      raise InvalidContext, "decision_context_message_mismatch" unless conversation.messages.exists?(id: normalized.fetch("message_id"))

      {
        conversation: conversation,
        guest_message: conversation.messages.find(normalized.fetch("message_id"))
      }
    rescue ActiveRecord::RecordNotFound, KeyError
      raise InvalidContext, "invalid_decision_context"
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
  end
end
