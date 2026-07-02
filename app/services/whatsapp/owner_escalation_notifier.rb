module Whatsapp
  class OwnerEscalationNotifier
    Result = Struct.new(:sent?, :session, :error, keyword_init: true)

    def self.call(alert:, provider: ProviderFactory.build)
      new(alert: alert, provider: provider).call
    end

    def self.drain_queue(account:, provider: ProviderFactory.build, except_session: nil)
      scope = account.owner_whatsapp_sessions
      scope = scope.where.not(id: except_session.id) if except_session
      session = scope.where(state: "queued").order(:created_at).first
      session ||= scope.where(state: "on_hold").order(:updated_at).first
      return unless session

      new(alert: session.alert, provider: provider).start_session(session)
    end

    def self.drain_queue_for_owner(owner_whatsapp_number:, provider: ProviderFactory.build, except_session: nil)
      scope = OwnerWhatsappSession.joins(:account).where(accounts: {
        owner_whatsapp_escalations_enabled: true,
        owner_whatsapp_number: owner_whatsapp_number
      })
      scope = scope.where.not(id: except_session.id) if except_session
      session = scope.where(state: "queued").order(:created_at).first
      session ||= scope.where(state: "on_hold").order(:updated_at).first
      return unless session

      new(alert: session.alert, provider: provider).start_session(session)
    end

    def initialize(alert:, provider:)
      @alert = alert
      @account = alert.property.account
      @provider = provider
    end

    def call
      return Result.new(sent?: false, session: nil, error: "owner_whatsapp_not_configured") unless @account.owner_whatsapp_configured?

      session = @account.owner_whatsapp_sessions.find_or_create_by!(alert: @alert)
      return Result.new(sent?: false, session: session, error: "another_alert_active") if active_other_session?(session)
      return Result.new(sent?: false, session: session, error: "already_active") if session.active?

      start_session(session)
    end

    def start_session(session)
      delivery = deliver_initial_notice(session.alert)
      unless delivery_success?(delivery)
        session.update!(state: "failed", metadata: session.metadata.merge("error" => delivery_error(delivery)))
        return Result.new(sent?: false, session: session, error: delivery_error(delivery))
      end

      session.alert.update!(status: "in_progress") if session.alert.status == "open"
      session.update!(
        state: "awaiting_ack",
        last_prompted_at: Time.current,
        metadata: session.metadata.merge(delivery_metadata(delivery)).compact
      )

      Result.new(sent?: true, session: session, error: nil)
    end

    private

    def deliver_initial_notice(alert)
      template_sid = ENV["TWILIO_OWNER_ESCALATION_TEMPLATE_SID"]
      if template_sid.present? && @provider.respond_to?(:send_template)
        return @provider.send_template(
          to: @account.owner_whatsapp_number,
          template_sid: template_sid,
          variables: {
            "1" => alert.property.display_name
          }
        )
      end

      @provider.send_message(to: @account.owner_whatsapp_number, body: template_message(alert))
    end

    def active_other_session?(session)
      OwnerWhatsappSession.joins(:account).active.where(accounts: {
        owner_whatsapp_escalations_enabled: true,
        owner_whatsapp_number: @account.owner_whatsapp_number
      }).where.not(id: session.id).exists?
    end

    def template_message(alert)
      "Ayla Manager: hay una consulta pendiente para #{alert.property.display_name}. Respondé OK para ver el detalle o HOLD para dejarla en espera."
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
