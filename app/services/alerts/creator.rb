module Alerts
  class Creator
    PRIORITY_BY_TYPE = {
      "emergency" => "urgent",
      "maintenance_issue" => "high",
      "complaint" => "high",
      "late_checkout_request" => "medium",
      "missing_item" => "medium",
      "owner_approval_required" => "medium",
      "missing_sensitive_information" => "medium",
      "unknown_question" => "medium"
    }.freeze

    def self.call(conversation:, decision:, owner_whatsapp_provider: nil)
      new(conversation: conversation, decision: decision, owner_whatsapp_provider: owner_whatsapp_provider).call
    end

    def initialize(conversation:, decision:, owner_whatsapp_provider: nil)
      @conversation = conversation
      @decision = decision
      @owner_whatsapp_provider = owner_whatsapp_provider
    end

    def call
      return unless @decision.escalation_required
      return unless account.ai_automation_enabled?("create_alerts")
      return unless account.ai_escalates?(@decision.alert_type)

      description = alert_description
      original_message = latest_guest_message_record
      alert = @conversation.alerts.create!(
        property: @conversation.property,
        guest: @conversation.guest,
        original_message: original_message,
        ai_decision_log: latest_ai_trace_for(original_message),
        alert_type: (@decision.alert_type.presence || "other").to_s,
        title: alert_title(description),
        description: description,
        priority: PRIORITY_BY_TYPE.fetch(@decision.alert_type.to_s, "medium"),
        ai_suggested_action: @decision.suggested_owner_action,
        metadata: {
          "source" => "ai_escalation",
          "decision" => @decision.outcome,
          "reason_code" => @decision.escalation&.fetch("reason_code", nil),
          "evidence_ids" => @decision.evidence_ids,
          "detected_intents" => @decision.detected_intents,
          "missing_information" => @decision.missing_information,
          "requested_sensitive_type" => requested_sensitive_type
        }.compact
      )

      if alert.priority == "urgent" && account.email_alerts_enabled? && account.ai_automation_enabled?("send_urgent_emails")
        OwnerAlertEmailJob.perform_later(alert.id)
      end

      if account.ai_automation_enabled?("send_owner_whatsapp_escalations")
        Whatsapp::OwnerEscalationNotifier.call(alert: alert, provider: @owner_whatsapp_provider || Whatsapp::ProviderFactory.build)
      end

      alert
    end

    def account
      @account ||= @conversation.property.account
    end

    def alert_description
      latest_guest_message = clean_guest_question(latest_guest_message_record&.body)
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

    def latest_guest_message_record
      @latest_guest_message_record ||= @conversation.messages.where(sender: "guest").order(created_at: :desc).first
    end

    def latest_ai_trace_for(message)
      return if message.blank?

      AIDecisionLog.where(conversation: @conversation, message: message).order(created_at: :desc).first ||
        AIDecisionLog.where(conversation: @conversation, original_message: message).order(created_at: :desc).first
    end

    def alert_title(description)
      if @decision.alert_type.to_s == "unknown_question" && description.present?
        return description.to_s.squish.truncate(120)
      end

      @decision.alert_title.presence || "El huésped necesita atención del propietario"
    end

    def requested_sensitive_type
      return unless @decision.alert_type.to_s == "missing_sensitive_information"

      @decision.missing_information.find { |item| item.to_s.start_with?("property.") }
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
