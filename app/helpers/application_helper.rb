module ApplicationHelper
  def nav_link_class(path)
    base = "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition"
    active = "bg-slate-900 text-white shadow-sm"
    inactive = "text-slate-600 hover:bg-white hover:text-slate-950"

    "#{base} #{current_page?(path) ? active : inactive}"
  end

  def sidebar_icon(name)
    paths = {
      dashboard: ["M3 3h7v7H3z", "M14 3h7v7h-7z", "M3 14h7v7H3z", "M14 14h7v7h-7z"],
      properties: ["M3 11.5 12 4l9 7.5", "M5.5 10.5V20h13v-9.5", "M9 20v-6h6v6"],
      conversations: ["M4 5h16v11H9l-5 4z"],
      requests: ["M8 4h8", "M9 3v3h6V3", "M6 5h12v16H6z", "m9 13 2 2 4-5"],
      inquiries: ["M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M9.5 9a2.5 2.5 0 1 1 3.6 2.25c-.8.45-1.1.85-1.1 1.75", "M12 17h.01"],
      alerts: ["M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9", "M10 21h4"],
      checkouts: ["M5 3h10v18H5z", "M15 12h6", "m18 9 3 3-3 3", "M9 12h.01"],
      users: ["M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", "M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z", "M22 21v-2a4 4 0 0 0-3-3.87", "M16 3.13a4 4 0 0 1 0 7.75"],
      stats: ["M4 20V10", "M10 20V4", "M16 20v-7", "M22 20V7"],
      errors: ["M10.3 3.7 2.4 18h19.2L13.7 3.7a2 2 0 0 0-3.4 0Z", "M12 9v4", "M12 17h.01"],
      ai_settings: ["m12 3 1.2 3.8L17 8l-3.8 1.2L12 13l-1.2-3.8L7 8l3.8-1.2Z", "m19 14 .7 2.3L22 17l-2.3.7L19 20l-.7-2.3L16 17l2.3-.7Z", "M5 15v6", "M2 18h6"],
      ai_trace: ["M3 12h4l2-6 4 12 2-6h6"]
    }

    content_tag(
      :svg,
      safe_join(paths.fetch(name).map { |path| tag.path(d: path) }),
      class: "h-5 w-5 shrink-0",
      viewBox: "0 0 24 24",
      fill: "none",
      stroke: "currentColor",
      "stroke-width": 1.8,
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      "aria-hidden": true
    )
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
      "rejected" => "Rechazado",
      "dismissed" => "Descartado",
      "cancelled" => "Cancelado",
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
      "business" => "Business",
      "scale" => "Scale",
      "pro" => "Pro",
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
      "food_or_drink" => "Comida o bebida",
      "extra_bed" => "Cama extra",
      "extra_item" => "Artículo extra",
      "service" => "Servicio",
      "early_checkin" => "Early check-in",
      "late_checkout" => "Late checkout",
      "reservation_change" => "Cambio de reserva",
      "normal" => "Normal",
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
    code = AI::LanguageHelper.normalize_code(value)
    t("ui.language_names.#{code}", default: code.to_s.upcase.presence || t("ui.language_names.unknown"))
  end

  def language_options
    [[language_label("es"), "es"], [language_label("en"), "en"]]
  end

  def conversation_message_body(message, preferred_language:, translation_mode:)
    return message.body if translation_mode == "original"

    message.translation_for(preferred_language)&.translated_body.presence || message.body
  end

  def conversation_message_translation_pending?(message, preferred_language:, translation_mode:)
    return false if translation_mode == "original"

    message.message_translations.any? do |translation|
      translation.target_language == preferred_language && translation.status.in?(%w[pending processing])
    end
  end

  def conversation_translation_source_labels(messages, preferred_language)
    messages.filter_map do |message|
      source = AI::LanguageHelper.normalize_code(message.detected_language)
      source if source.present? && source != preferred_language
    end.uniq.map { |language| language_label(language) }
  end

  def subscription_commercial_label(subscription)
    return "Sin suscripción" if subscription.blank?
    return "Prueba gratis" if subscription.trialing?
    return billing_plan_name(subscription.plan) if subscription.paying?

    enum_label(subscription.status)
  end

  def billing_plan_name(plan)
    Billing::Plans.all.find { |definition| definition[:id] == plan.to_s }&.fetch(:name) || enum_label(plan)
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
    if alert.alert_type.to_s == "unknown_question" && alert.original_message&.body.present?
      return alert.original_message.body.to_s.squish
    end

    {
      "late_checkout_request" => "Pedido para salir más tarde",
      "missing_item" => "El huésped informa que falta algo",
      "maintenance_issue" => "Hay un problema en la propiedad",
      "emergency" => "Situación urgente",
      "complaint" => "El huésped hizo un reclamo",
      "owner_approval_required" => "El huésped necesita tu aprobación",
      "missing_sensitive_information" => "Ayla necesita información para responder",
      "unknown_question" => "El huésped necesita una respuesta"
    }.fetch(alert.alert_type.to_s, alert.title)
  end

  def alert_display_description(alert)
    original_message = alert.original_message&.body.to_s.squish
    return "El huésped escribió: “#{original_message}”" if original_message.present?

    description = owner_friendly_alert_description(alert.description)
    return if description.blank?
    return if description == alert_display_title(alert).to_s.squish

    description
  end

  def owner_friendly_alert_description(value)
    text = value.to_s.strip
    return if text.blank?
    return text.squish unless text.start_with?("{", "[")

    payload = JSON.parse(text)
    payload = payload.first if payload.is_a?(Array)
    return unless payload.is_a?(Hash)

    guest_message = payload["guest_message"].to_s.squish.presence
    requested_time = payload["requested_time"].to_s.squish.presence
    requested_for = payload["requested_for"].to_s.squish.presence
    note = payload["note"].to_s.squish.presence

    parts = []
    parts << "El huésped escribió: “#{guest_message}”" if guest_message
    parts << "Horario solicitado: #{requested_time}." if requested_time && !guest_message.to_s.include?(requested_time)
    parts << "Para: #{requested_for}." if requested_for && !guest_message.to_s.include?(requested_for)
    parts << note unless note && (guest_message.to_s.include?(note) || parts.any? { |part| part.include?(note) })
    parts.compact_blank.join(" ").presence
  rescue JSON::ParserError
    "Revisá el mensaje del huésped para entender qué necesita."
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
