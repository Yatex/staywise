module Whatsapp
  class HostReplyDelivery
    Result = Struct.new(:sent?, :already_handled?, :owner_message, :error, keyword_init: true)

    def initialize(item:, actor:, session:, provider:, source_message_sid:, on_success: nil, on_failure: nil)
      @item = item
      @actor = actor
      @session = session
      @provider = provider
      @source_message_sid = source_message_sid
      @on_success = on_success
      @on_failure = on_failure
    end

    def call
      draft = @session.draft_reply_body.to_s
      claim = claim!(draft)
      return Result.new(sent?: false, already_handled?: true, error: "already_handled") unless claim

      conversation = @item.conversation
      owner_message = conversation.messages.create!(
        sender: "owner", channel: "whatsapp", body: draft,
        metadata: {
          sent_via: "owner_whatsapp_queue", owner_phone_number: @actor.phone_number,
          actor_role: @actor.role, actor_type: @actor.type, actor_id: @actor.id,
          active_item_type: @session.active_item_type, active_item_id: @session.active_item_id,
          delivery_status: "pending", delivery_status_updated_at: Time.current.iso8601
        }
      )
      delivery = @provider.send_message(to: conversation.guest.phone_number, body: draft)
      unless delivery_success?(delivery)
        fail_claim!(delivery)
        owner_message.update!(metadata: owner_message.metadata.merge("delivery_status" => "failed", "delivery_error" => delivery_error(delivery)))
        return Result.new(sent?: false, already_handled?: false, owner_message: owner_message, error: delivery_error(delivery))
      end

      @item.with_lock do
        @item.update!(
          response_delivery_state: "responded", status: "resolved", resolved_at: Time.current, final_response_body: draft
        )
        @on_success&.call(@item, owner_message)
      end
      owner_message.update!(metadata: owner_message.metadata.merge("delivery_status" => "sent"))
      Result.new(sent?: true, already_handled?: false, owner_message: owner_message)
    end

    private

    def claim!(draft)
      @item.with_lock do
        @session.reload
        return false unless valid_session_draft?(draft)
        return false unless @actor.can_manage_property?(@item.property)
        return false unless @item.status == "open"
        return false if @item.response_delivery_state.in?(%w[sending responded])
        if @item.claimed_response_body.present?
          return false unless same_actor? && @item.claimed_response_body == draft
        end

        @item.update!(
          response_delivery_state: "sending",
          claimed_response_body: draft,
          resolved_by_actor_type: @actor.type,
          resolved_by_actor_id: @actor.id,
          resolved_by_role: @actor.role,
          source_owner_message_sid: @source_message_sid
        )
        true
      end
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def fail_claim!(delivery)
      @item.with_lock do
        if @item.response_delivery_state == "sending" && same_actor?
          @item.update!(response_delivery_state: "failed")
          @on_failure&.call(@item)
        end
      end
      ErrorReporter.report(
        source: "owner_whatsapp_reply",
        severity: "error",
        account: @actor.account,
        property: @item.property,
        message: "Host WhatsApp reply delivery failed",
        context: { actor_role: @actor.role, actor_id: @actor.id, item_type: @item.class.base_class.name,
                   item_id: @item.id, error: delivery_error(delivery) }
      )
    end

    def same_actor?
      @item.resolved_by_actor_type == @actor.type && @item.resolved_by_actor_id == @actor.id
    end

    def valid_session_draft?(draft)
      @session.account_id == @actor.account.id &&
        @session.participant_phone == @actor.phone_number &&
        @session.actor_role == @actor.role &&
        @session.co_host_id == @actor.co_host&.id &&
        @session.draft_for_active_item? &&
        @session.active_item_type == @item.class.base_class.name &&
        @session.active_item_id == @item.id &&
        @session.draft_reply_body == draft
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_error(delivery)
      delivery.respond_to?(:error) && delivery.error.present? ? delivery.error : "whatsapp_delivery_failed"
    end
  end
end
