require "test_helper"

class WhatsappHostReplyConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class ConcurrentProvider < Whatsapp::Providers::NullProvider
    attr_reader :deliveries

    def initialize
      @deliveries = []
      @mutex = Mutex.new
    end

    def send_message(to:, body:, media_urls: [])
      sleep 0.05
      @mutex.synchronize { @deliveries << { to: to, body: body } }
      true
    end
  end

  setup do
    @account = Account.create!(name: "Concurrency #{SecureRandom.hex(4)}", owner_whatsapp_number: "+598992#{rand(10_000..99_999)}",
      owner_whatsapp_escalations_enabled: true)
    @property = @account.properties.create!(name: "Concurrent property")
    @co_host = @account.co_hosts.create!(name: "Co-host", whatsapp_number: "+598993#{rand(10_000..99_999)}")
    @property.update!(co_host: @co_host)
    @guest = @account.guests.create!(phone_number: "+598994#{rand(10_000..99_999)}", property: @property)
    @conversation = @guest.conversations.create!(property: @property)
    message = @conversation.messages.create!(sender: "guest", channel: "whatsapp", body: "Can I get towels?")
    @task = @conversation.owner_tasks.create!(account: @account, property: @property, guest: @guest, message: message,
      kind: "request", guest_phone: @guest.phone_number, property_name: @property.display_name, category: "other",
      title: "Towels", description: message.body, status: "open", source_channel: "whatsapp")
    @owner_session = session_for(Whatsapp::HostActor.owner(@account), "Owner exact response")
    @co_host_session = session_for(Whatsapp::HostActor.co_host(@co_host), "Co-host exact response")
    @provider = ConcurrentProvider.new
    @sid_token = SecureRandom.hex(8)
  end

  teardown do
    @task&.destroy! if @task&.persisted?
    @account.owner_whatsapp_sessions.delete_all
    @conversation.messages.delete_all
    @conversation.delete
    @guest.delete
    @property.update_column(:co_host_id, nil)
    @co_host.delete
    Property.with_deleted.where(id: @property.id).delete_all
    @account.delete
  end

  test "two concurrent confirmations perform one external delivery and persist one winner" do
    ready = Queue.new
    start = Queue.new
    actors_and_sessions = [
      [Whatsapp::HostActor.owner(@account), @owner_session, "SM-CONCURRENT-OWNER-#{@sid_token}"],
      [Whatsapp::HostActor.co_host(@co_host), @co_host_session, "SM-CONCURRENT-COHOST-#{@sid_token}"]
    ]

    results = actors_and_sessions.map do |actor, session, sid|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          item = OwnerTask.find(@task.id)
          persisted_session = OwnerWhatsappSession.find(session.id)
          ready << true
          start.pop
          Whatsapp::HostReplyDelivery.new(item: item, actor: actor, session: persisted_session,
            provider: @provider, source_message_sid: sid).call
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = results.map(&:value)

    assert_equal 1, results.count(&:sent?)
    assert_equal 1, results.count(&:already_handled?)
    assert_equal 1, @provider.deliveries.size
    assert_equal "responded", @task.reload.response_delivery_state
    assert_equal "resolved", @task.status
    assert_includes ["Owner exact response", "Co-host exact response"], @task.final_response_body
    assert_equal @task.final_response_body, @provider.deliveries.first[:body]
    assert_equal 1, @conversation.messages.where(sender: "owner").count
  end

  private

  def session_for(actor, draft)
    @account.owner_whatsapp_sessions.create!(
      state: "awaiting_send_confirmation", participant_phone: actor.phone_number, actor_role: actor.role,
      co_host: actor.co_host, active_category: "pedidos", active_item_type: "OwnerTask", active_item_id: @task.id,
      draft_reply_body: draft, draft_item_type: "OwnerTask", draft_item_id: @task.id,
      started_at: Time.current, expires_at: 30.minutes.from_now
    )
  end
end
