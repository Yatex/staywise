module Copilot
  class ToolContext
    PURPOSE = :copilot_tool_context
    TTL = 10.minutes

    class InvalidContext < StandardError; end

    def self.issue(thread:, message:)
      verifier.generate(
        {
          account_id: thread.account_id,
          property_id: thread.property_id,
          user_id: thread.user_id,
          thread_id: thread.id,
          message_id: message.id
        },
        expires_in: TTL
      )
    end

    def self.resolve(token)
      payload = verifier.verified(token)
      raise InvalidContext, "invalid_copilot_context" unless payload.is_a?(Hash)

      ids = payload.stringify_keys
      thread = CopilotThread.includes(:account, :property, :user).find(ids.fetch("thread_id"))
      message = thread.copilot_messages.find(ids.fetch("message_id"))
      valid = thread.account_id == ids.fetch("account_id") &&
        thread.property_id == ids.fetch("property_id") &&
        thread.user_id == ids.fetch("user_id") &&
        message.account_id == thread.account_id &&
        message.property_id == thread.property_id &&
        message.user_id == thread.user_id &&
        message.role == "host"
      raise InvalidContext, "copilot_context_scope_mismatch" unless valid

      { thread: thread, message: message }
    rescue ActiveRecord::RecordNotFound, KeyError
      raise InvalidContext, "invalid_copilot_context"
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
  end
end
