module Whatsapp
  class OwnerEscalationNotifier
    Result = Struct.new(:sent?, :session, :error, keyword_init: true)

    def self.call(alert: nil, item: nil, account: nil, provider: ProviderFactory.build)
      item ||= alert
      account ||= item&.property&.account
      new(account: account, provider: provider).call
    end

    def self.drain_queue(account:, provider: ProviderFactory.build, except_session: nil)
      call(account: account, provider: provider)
    end

    def self.drain_queue_for_owner(owner_whatsapp_number:, provider: ProviderFactory.build, except_session: nil)
      accounts = Account.where(
        owner_whatsapp_escalations_enabled: true,
        owner_whatsapp_number: owner_whatsapp_number
      )
      accounts.filter_map { |account| call(account: account, provider: provider) }.find(&:sent?)
    end

    def initialize(account:, provider:)
      @account = account
      @provider = provider
    end

    def call
      return Result.new(sent?: false, session: nil, error: "owner_whatsapp_not_configured") unless @account.owner_whatsapp_configured?

      expire_active_session!
      if (session = @account.owner_whatsapp_sessions.active.order(created_at: :desc).first)
        return Result.new(sent?: false, session: session, error: "owner_session_active")
      end
      return Result.new(sent?: false, session: nil, error: "nothing_pending") if pending_counts.values.sum.zero?

      session = @account.owner_whatsapp_sessions.create!(state: "menu", started_at: Time.current, expires_at: 30.minutes.from_now)
      notify_session(session)
    rescue ActiveRecord::RecordNotUnique
      session = @account.owner_whatsapp_sessions.active.order(created_at: :desc).first
      Result.new(sent?: false, session: session, error: "owner_session_active")
    end

    def notify_session(session)
      delivery = deliver_initial_notice
      unless delivery_success?(delivery)
        session.update!(
          state: "queued",
          metadata: session.metadata.merge(
            "last_notification_error" => delivery_error(delivery),
            "last_notification_failed_at" => Time.current.iso8601
          )
        )
        session.append_event!("owner_alert_notification_failed", error: delivery_error(delivery))
        return Result.new(sent?: false, session: session, error: delivery_error(delivery))
      end

      session.update!(
        state: session.state,
        last_prompted_at: Time.current,
        metadata: session.metadata.merge(delivery_metadata(delivery)).compact
      )
      session.append_event!("owner_pending_notification_sent", counts: pending_counts)

      Result.new(sent?: true, session: session, error: nil)
    end

    private

    def deliver_initial_notice
      template_sid = ENV["TWILIO_OWNER_ESCALATION_NOTICE_CONTENT_SID"]
      if template_sid.present? && @provider.respond_to?(:send_template)
        return @provider.send_template(
          to: @account.owner_whatsapp_number,
          template_sid: template_sid,
          variables: initial_notice_variables(template_sid)
        )
      end

      @provider.send_message(to: @account.owner_whatsapp_number, body: template_message)
    end

    def template_message
      counts = pending_counts
      "Pendientes en Ayla: #{counts[:pedidos]} pedidos, #{counts[:consultas]} consultas, #{counts[:alertas]} alertas y #{counts[:checkouts]} checkouts."
    end

    def pending_counts
      @pending_counts ||= {
        pedidos: @account.owner_tasks.open.requests.count,
        consultas: @account.owner_tasks.open.inquiries.count,
        alertas: Alert.joins(:property).where(properties: { account_id: @account.id }).open.count,
        checkouts: @account.checkout_events.pending.count
      }
    end

    def initial_notice_variables(template_sid)
      variables = {
        "1" => pending_counts[:pedidos].to_s,
        "2" => pending_counts[:consultas].to_s,
        "3" => pending_counts[:alertas].to_s
      }
      variables["4"] = pending_counts[:checkouts].to_s if template_supports_checkouts?(template_sid)
      variables
    end

    def template_supports_checkouts?(template_sid)
      @provider.respond_to?(:template_supports_action?) && @provider.template_supports_action?(template_sid, "checkouts")
    end

    def expire_active_session!
      @account.owner_whatsapp_sessions.active.where("expires_at <= ?", Time.current).find_each do |session|
        session.update!(state: "resolved", resolved_at: Time.current, active_category: nil, active_item_type: nil, active_item_id: nil)
      end
    end

    def delivery_success?(delivery)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end

    def delivery_error(delivery)
      delivery.respond_to?(:error) && delivery.error.present? ? delivery.error : "owner_whatsapp_delivery_failed"
    end

    def delivery_metadata(delivery)
      return {} unless delivery.respond_to?(:provider_message_id)

      {
        "provider_message_id" => delivery.provider_message_id,
        "provider_status" => delivery.provider_status,
        "delivery_status_updated_at" => Time.current.iso8601
      }
    end
  end
end
