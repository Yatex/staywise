module ApplicationHelper
  def nav_link_class(path)
    base = "block rounded-lg px-3 py-2 text-sm font-medium transition"
    active = "bg-slate-900 text-white shadow-sm"
    inactive = "text-slate-600 hover:bg-white hover:text-slate-950"

    "#{base} #{current_page?(path) ? active : inactive}"
  end

  def pill_class(value)
    case value.to_s
    when "active", "trialing", "resolved"
      "bg-emerald-50 text-emerald-700 ring-emerald-200"
    when "urgent", "high", "escalated", "past_due", "error", "critical"
      "bg-rose-50 text-rose-700 ring-rose-200"
    when "open", "in_progress", "medium", "warning"
      "bg-amber-50 text-amber-700 ring-amber-200"
    else
      "bg-slate-100 text-slate-600 ring-slate-200"
    end
  end

  def enum_label(value)
    translated = t("enums.#{value}", default: nil)
    return translated if translated.present?

    translations = {
      "active" => "Activo",
      "archived" => "Archivado",
      "trialing" => "En prueba",
      "resolved" => "Resuelto",
      "dismissed" => "Descartado",
      "urgent" => "Urgente",
      "high" => "Alta",
      "medium" => "Media",
      "low" => "Baja",
      "escalated" => "Escalado",
      "past_due" => "Pago vencido",
      "open" => "Abierta",
      "in_progress" => "En progreso",
      "closed" => "Cerrada",
      "paused" => "Pausada",
      "inactive" => "Inactivo",
      "draft" => "Borrador",
      "incomplete" => "Incompleta",
      "canceled" => "Cancelada",
      "owner" => "Propietario",
      "admin" => "Administrador",
      "member" => "Miembro",
      "guest" => "Huésped",
      "ai" => "IA",
      "system" => "Sistema",
      "starter" => "Starter",
      "growth" => "Growth",
      "pro" => "Scale",
      "business" => "Pro",
      "concise" => "Conciso",
      "warm" => "Cálido",
      "detailed" => "Detallado",
      "whatsapp" => "WhatsApp",
      "check_in" => "Check-in",
      "checkout" => "Checkout",
      "wifi" => "WiFi",
      "appliances" => "Electrodomésticos",
      "house_rules" => "Reglas de la casa",
      "amenities" => "Comodidades",
      "building_access" => "Acceso al edificio",
      "transportation" => "Transporte",
      "emergencies" => "Emergencias",
      "custom_notes" => "Notas personalizadas",
      "restaurant" => "Restaurante",
      "cafe" => "Café",
      "supermarket" => "Supermercado",
      "pharmacy" => "Farmacia",
      "attraction" => "Atracción",
      "transport" => "Transporte",
      "other" => "Otro",
      "late_checkout_request" => "Solicitud de late checkout",
      "missing_item" => "Objeto faltante",
      "maintenance_issue" => "Problema de mantenimiento",
      "emergency" => "Emergencia",
      "complaint" => "Queja",
      "owner_approval_required" => "Requiere aprobación del propietario",
      "unknown_question" => "Pregunta sin configurar",
      "send_whatsapp_replies" => "Enviar respuestas por WhatsApp",
      "create_alerts" => "Crear alertas",
      "send_urgent_emails" => "Enviar emails urgentes",
      "info" => "Info",
      "warning" => "Advertencia",
      "error" => "Error",
      "critical" => "Crítico",
      "whatsapp_webhook" => "Webhook WhatsApp",
      "twilio_provider" => "Twilio",
      "ai_service" => "Servicio AI",
      "stripe_webhook" => "Webhook Stripe",
      "stripe_checkout" => "Checkout Stripe",
      "stripe_portal" => "Portal Stripe",
      "email_service" => "Email"
    }

    translations.fetch(value.to_s, value.to_s.humanize)
  end

  def locale_path(locale)
    query = request.query_parameters.merge(locale: locale).compact_blank.to_query
    [request.path, query.presence].compact.join("?")
  end

  def locale_label(locale)
    t("ui.locales.#{locale}")
  end

  def language_label(value)
    { "en" => "Inglés", "es" => "Español" }.fetch(value.to_s, "Español")
  end

  def language_options
    [["Español", "es"], ["Inglés", "en"]]
  end

  def subscription_commercial_label(subscription)
    return "Sin suscripción" if subscription.blank?
    return "Prueba gratis" if subscription.trialing?
    return enum_label(subscription.plan) if subscription.paying?

    enum_label(subscription.status)
  end

  def subscription_end_label(subscription)
    return "Sin configurar" if subscription.blank?

    if subscription.trialing?
      return "La prueba termina #{subscription.trial_ends_on.to_fs(:long)}" if subscription.trial_ends_on.present?

      "Prueba sin fecha final configurada"
    elsif subscription.current_period_end.present?
      "Termina #{subscription.current_period_end.to_date.to_fs(:long)}"
    else
      "Termina sin configurar"
    end
  end

  def trial_days_label(subscription)
    return unless subscription&.trialing? && subscription.trial_days_remaining.present?

    days = subscription.trial_days_remaining
    days == 1 ? "queda 1 día" : "quedan #{days} días"
  end

  def local_datetime(value)
    return if value.blank?

    I18n.l(value.in_time_zone, format: :short)
  end

  def local_long_datetime(value)
    return if value.blank?

    I18n.l(value.in_time_zone, format: :long)
  end

  def local_date(value)
    return if value.blank?

    value.in_time_zone.to_date.to_fs(:long)
  end

  def whatsapp_delivery_label(message)
    status = message.metadata["delivery_status"].presence || message.metadata["provider_status"].presence

    case status
    when "delivered"
      "Entregado por WhatsApp"
    when "sent"
      "Enviado por WhatsApp"
    when "queued", "accepted", "accepted_by_provider"
      "Aceptado por Twilio"
    when "failed"
      "Falló el envío por WhatsApp"
    when "undelivered"
      "WhatsApp no pudo entregarlo"
    else
      "Enviado desde Ayla"
    end
  end

  def whatsapp_delivery_failed?(message)
    message.metadata["delivery_status"].to_s.in?(%w[failed undelivered])
  end

  def alert_display_title(alert)
    if alert.alert_type.to_s == "unknown_question" && alert.description.present?
      return alert.description.to_s.squish
    end

    alert.title
  end

  def alert_display_description(alert)
    description = alert.description.to_s.squish
    return if description.blank?
    return if description == alert_display_title(alert).to_s.squish

    description
  end

  def display_phone_number(value)
    value.to_s
      .delete_prefix("whatsapp:")
      .delete_prefix("+")
      .presence
  end

  def conversation_display_title(conversation)
    display_phone_number(conversation.guest&.phone_number) ||
      conversation.guest&.display_name ||
      "Huésped"
  end

  def property_tag_class
    "inline-flex w-fit items-center rounded-full bg-slate-100 px-2 py-1 text-xs font-semibold text-slate-600 ring-1 ring-slate-200"
  end

  def card_class
    "rounded-xl border border-slate-200 bg-white shadow-sm"
  end

  def field_class
    "mt-2 w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-slate-400 focus:ring-4 focus:ring-slate-100"
  end

  def trace_json(value)
    JSON.pretty_generate(AIDecisionLog.sanitize_trace(value || {}))
  rescue JSON::GeneratorError, TypeError
    AIDecisionLog.sanitize_trace(value).inspect
  end

  def trace_value(value)
    return "Sin datos" if value.blank?

    value
  end

  def trace_evidence_value(evidence)
    evidence = evidence.to_h
    field = evidence["field"] || evidence[:field] || "value"
    value = evidence["value"] || evidence[:value]

    AIDecisionLog.sanitize_trace({ field => value }).values.first.presence || "Sin datos"
  end

  def ai_decision_scores(trace)
    trace.ai_response_payload.to_h.dig("audit", "grounded_decision_builder", "decision_scores").presence ||
      trace.ai_response_payload.to_h.dig("audit", "grounded_decision_trace", "decision_scores").presence ||
      trace.payload.to_h.dig("decision_scores").presence ||
      {}
  end

  def ai_decision_thresholds(trace)
    trace.ai_response_payload.to_h.dig("audit", "grounded_decision_builder", "score_thresholds").presence ||
      trace.ai_response_payload.to_h.dig("audit", "grounded_decision_trace", "score_thresholds").presence ||
      {}
  end

  def ai_decision_answer(trace)
    trace.ai_response_payload.to_h["message_body"].presence ||
      trace.ai_response_payload.to_h["response_text"].presence ||
      trace.payload.to_h.dig("rejected_candidate", "response_text").presence ||
      "Respuesta no disponible"
  end

  def ai_decision_candidate_answer(trace)
    trace.payload.to_h.dig("rejected_candidate", "response_text").presence ||
      trace.ai_response_payload.to_h["message_body"].presence ||
      trace.ai_response_payload.to_h["response_text"].presence ||
      "Respuesta candidata no disponible"
  end

  def ai_decision_final_answer(trace)
    trace.payload.to_h["final_response_text"].presence ||
      trace.ai_response_payload.to_h["message_body"].presence ||
      trace.ai_response_payload.to_h["response_text"].presence ||
      trace.final_outcome.presence ||
      "Respuesta final no disponible"
  end

  def ai_decision_original_outcome(trace)
    trace.payload.to_h.dig("rejected_candidate", "outcome").presence ||
      trace.ai_response_payload.to_h["outcome"].presence ||
      trace.ai_response_payload.to_h["decision"].presence ||
      trace.decision
  end

  def ai_decision_rejection_reason(trace)
    trace.rejection_reason.presence ||
      Array(trace.validation_results.to_h["reasons"]).join(", ").presence ||
      "Sin rechazo"
  end

  def label_class
    "text-sm font-medium text-slate-700"
  end

  def primary_button_class
    "inline-flex items-center justify-center rounded-lg bg-slate-900 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-slate-800"
  end

  def secondary_button_class
    "inline-flex items-center justify-center rounded-lg border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm transition hover:bg-slate-50"
  end
end
