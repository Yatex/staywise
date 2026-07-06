module Alerts
  class Creator
    PRIORITY_BY_TYPE = {
      "emergency" => "urgent",
      "maintenance_issue" => "high",
      "complaint" => "high",
      "late_checkout_request" => "medium",
      "missing_item" => "medium",
      "owner_approval_required" => "medium",
      "unknown_question" => "medium"
    }.freeze

    def self.call(conversation:, decision:)
      new(conversation: conversation, decision: decision).call
    end

    def initialize(conversation:, decision:)
      @conversation = conversation
      @decision = decision
    end

    def call
      return unless @decision.escalation_required
      return unless account.ai_automation_enabled?("create_alerts")
      return unless account.ai_escalates?(@decision.alert_type)

      description = alert_description
      alert = @conversation.alerts.create!(
        property: @conversation.property,
        guest: @conversation.guest,
        alert_type: (@decision.alert_type.presence || "other").to_s,
        title: alert_title(description),
        description: description,
        priority: PRIORITY_BY_TYPE.fetch(@decision.alert_type.to_s, "medium"),
        ai_suggested_action: @decision.suggested_owner_action
      )

      if alert.priority == "urgent" && account.email_alerts_enabled? && account.ai_automation_enabled?("send_urgent_emails")
        OwnerAlertEmailJob.perform_later(alert.id)
      end

      Whatsapp::OwnerEscalationNotifier.call(alert: alert) if account.ai_automation_enabled?("send_owner_whatsapp_escalations")

      alert
    end

    def account
      @account ||= @conversation.property.account
    end

    def alert_description
      latest_guest_message = clean_guest_question(@conversation.messages.where(sender: "guest").order(created_at: :desc).first&.body)
      text = if @decision.alert_type.to_s == "unknown_question"
        latest_guest_message.presence || @decision.alert_description
      else
        @decision.alert_description.presence || latest_guest_message
      end

      AI::Translator.call(
        text: text,
        source_language: @decision.language || @conversation.guest.language,
        target_language: AI::LanguageHelper.owner_language(account),
        context: "Owner-facing alert description for a short-term rental host."
      )
    end

    def alert_title(description)
      if @decision.alert_type.to_s == "unknown_question" && description.present?
        return description.to_s.squish.truncate(120)
      end

      @decision.alert_title.presence || "El huésped necesita atención del propietario"
    end

    def clean_guest_question(text)
      text.to_s
        .delete_prefix(@conversation.property.whatsapp_reference)
        .gsub(@conversation.property.whatsapp_reference, "")
        .strip
        .presence
    end
  end
end
