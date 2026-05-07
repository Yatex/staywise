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

      alert = @conversation.alerts.create!(
        property: @conversation.property,
        guest: @conversation.guest,
        alert_type: (@decision.alert_type.presence || "other").to_s,
        title: @decision.alert_title.presence || "Guest needs owner attention",
        description: @decision.alert_description,
        priority: PRIORITY_BY_TYPE.fetch(@decision.alert_type.to_s, "medium"),
        ai_suggested_action: @decision.suggested_owner_action
      )

      if alert.priority == "urgent" && account.email_alerts_enabled? && account.ai_automation_enabled?("send_urgent_emails")
        OwnerAlertEmailJob.perform_later(alert.id)
      end

      alert
    end

    def account
      @account ||= @conversation.property.account
    end
  end
end
