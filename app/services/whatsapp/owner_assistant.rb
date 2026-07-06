module Whatsapp
  class OwnerAssistant
    QUERY_PATTERN = /\Aayla\s+(resumen|summary|stats|estad[ií]sticas|reporte|pendientes|alertas)\b/i

    def self.query?(body)
      normalized = body.to_s.strip
      normalized.match?(QUERY_PATTERN)
    end

    def self.call(owner_whatsapp_number:, body:, provider: ProviderFactory.build)
      new(owner_whatsapp_number: owner_whatsapp_number, body: body, provider: provider).call
    end

    def initialize(owner_whatsapp_number:, body:, provider:)
      @owner_whatsapp_number = owner_whatsapp_number
      @body = body.to_s
      @provider = provider
    end

    def call
      return send_owner_message("No encontré cuentas conectadas a este WhatsApp.") if accounts.blank?

      send_owner_message(response_body)
    end

    private

    def response_body
      if pending_query?
        pending_response
      elsif question_query?
        questions_response
      else
        summary_response
      end
    end

    def summary_response
      lines = [
        "Resumen de Ayla #{period_label}:",
        "- Consultas de huéspedes: #{guest_messages_count}",
        "- Conversaciones con actividad: #{active_conversations_count}",
        "- Respuestas de IA: #{ai_messages_count}",
        "- Respuestas del anfitrión: #{owner_messages_count}",
        "- Alertas creadas: #{alerts_count} (#{open_alerts_count} abiertas, #{resolved_alerts_count} resueltas)",
        "- Tiempo promedio de primera respuesta: #{average_first_response_label}",
        "- Conversaciones esperando respuesta: #{unanswered_conversations_count}"
      ]

      lines << ""
      lines << "Pendientes ahora:"
      lines.concat(pending_alert_lines.presence || ["- No hay alertas pendientes."])

      lines << ""
      lines << "Propiedades con más actividad:"
      lines.concat(top_property_lines.presence || ["- Sin actividad en el período."])

      lines << ""
      lines << "Tipos de alerta más frecuentes:"
      lines.concat(top_alert_type_lines.presence || ["- Sin alertas en el período."])

      lines.join("\n")
    end

    def pending_response
      lines = ["Pendientes ahora:"]
      lines.concat(pending_alert_lines(limit: 10).presence || ["- No hay alertas pendientes."])
      lines.join("\n")
    end

    def questions_response
      lines = ["Preguntas recientes escaladas #{period_label}:"]
      lines.concat(recent_question_lines.presence || ["- No hubo preguntas escaladas en el período."])
      lines.join("\n")
    end

    def pending_query?
      normalized_body.match?(/\b(pendientes|abiertas|sin responder|alertas)\b/) && !normalized_body.match?(/\b(resumen|estad[ií]sticas|stats|reporte)\b/)
    end

    def question_query?
      normalized_body.match?(/\b(preguntas|repitieron|repetidas|consultaron)\b/)
    end

    def normalized_body
      @normalized_body ||= @body.downcase
    end

    def accounts
      @accounts ||= Account.where(owner_whatsapp_escalations_enabled: true, owner_whatsapp_number: @owner_whatsapp_number)
    end

    def account_ids
      @account_ids ||= accounts.pluck(:id)
    end

    def properties
      @properties ||= Property.where(account_id: account_ids)
    end

    def property_ids
      @property_ids ||= properties.pluck(:id)
    end

    def period_range
      @period_range ||= period_start..Time.current
    end

    def period_start
      if (days = normalized_body.match(/(?:[uú]ltimos?|ultimos?)\s+(\d{1,2})\s+d[ií]as?/)&.[](1))
        days.to_i.clamp(1, 90).days.ago
      elsif normalized_body.match?(/\b(hoy|today)\b/)
        Time.current.beginning_of_day
      elsif normalized_body.match?(/\b(ayer|yesterday)\b/)
        1.day.ago.beginning_of_day
      elsif normalized_body.match?(/\b(mes|month|30)\b/)
        30.days.ago
      elsif normalized_body.match?(/\b(semana|week|7|estos d[ií]as|estos dias)\b/)
        7.days.ago
      else
        7.days.ago
      end
    end

    def period_label
      if normalized_body.match?(/\b(hoy|today)\b/)
        "de hoy"
      elsif normalized_body.match?(/\b(ayer|yesterday)\b/)
        "de ayer"
      elsif normalized_body.match?(/\b(mes|month|30)\b/)
        "de los últimos 30 días"
      elsif (days = normalized_body.match(/(?:[uú]ltimos?|ultimos?)\s+(\d{1,2})\s+d[ií]as?/)&.[](1))
        "de los últimos #{days.to_i.clamp(1, 90)} días"
      else
        "de los últimos 7 días"
      end
    end

    def messages_scope
      @messages_scope ||= Message.joins(conversation: :property)
        .where(properties: { account_id: account_ids })
        .where(created_at: period_range)
    end

    def guest_messages
      @guest_messages ||= messages_scope.where(sender: "guest")
    end

    def alerts_scope
      @alerts_scope ||= Alert.where(property_id: property_ids).where(created_at: period_range)
    end

    def open_alerts_scope
      @open_alerts_scope ||= Alert.open.where(property_id: property_ids)
    end

    def guest_messages_count
      guest_messages.count
    end

    def active_conversations_count
      messages_scope.select(:conversation_id).distinct.count
    end

    def ai_messages_count
      messages_scope.where(sender: "ai").count
    end

    def owner_messages_count
      messages_scope.where(sender: "owner").count
    end

    def alerts_count
      alerts_scope.count
    end

    def open_alerts_count
      open_alerts_scope.count
    end

    def resolved_alerts_count
      alerts_scope.where(status: "resolved").count
    end

    def unanswered_conversations_count
      Conversation.open.where(property_id: property_ids).includes(:messages).count do |conversation|
        conversation.messages.order(:created_at).last&.sender == "guest"
      end
    end

    def average_first_response_label
      seconds = first_response_seconds
      return "sin datos" if seconds.blank?

      average = seconds.sum / seconds.size
      if average < 60
        "#{average.round}s"
      elsif average < 3600
        "#{(average / 60.0).round} min"
      else
        "#{(average / 3600.0).round(1)} h"
      end
    end

    def first_response_seconds
      @first_response_seconds ||= guest_messages.order(:created_at).limit(200).filter_map do |message|
        response = message.conversation.messages
          .where("created_at > ?", message.created_at)
          .where(sender: %w[ai owner])
          .order(:created_at)
          .first
        next unless response

        response.created_at - message.created_at
      end
    end

    def pending_alert_lines(limit: 5)
      open_alerts_scope.includes(:property).order(created_at: :desc).limit(limit).map do |alert|
        "- #{alert.property.display_name}: #{alert.description.presence || alert.title} (#{ApplicationController.helpers.enum_label(alert.alert_type)})"
      end
    end

    def top_property_lines
      counts = guest_messages.joins(conversation: :property).group("properties.id").count
      counts.sort_by { |_id, count| -count }.first(5).map do |property_id, count|
        property = properties.find { |item| item.id == property_id }
        "- #{property&.display_name || "Propiedad #{property_id}"}: #{count} consultas"
      end
    end

    def top_alert_type_lines
      alerts_scope.group(:alert_type).count.sort_by { |_type, count| -count }.first(5).map do |type, count|
        "- #{ApplicationController.helpers.enum_label(type)}: #{count}"
      end
    end

    def recent_question_lines
      alerts_scope.unknown_questions.includes(:property).order(created_at: :desc).limit(8).map do |alert|
        "- #{alert.property.display_name}: #{alert.description.presence || alert.title}"
      end
    end

    def send_owner_message(body)
      delivery = @provider.send_message(to: @owner_whatsapp_number, body: body)
      delivery.respond_to?(:success?) ? delivery.success? : !!delivery
    end
  end
end
