module OwnerTasks
  class Creator
    def self.call(conversation:, decision:, guest_message:)
      GuestRequests::Creator.call(conversation: conversation, decision: decision, guest_message: guest_message)
    end
  end
end
