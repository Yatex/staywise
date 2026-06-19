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
    when "urgent", "high", "escalated", "past_due"
      "bg-rose-50 text-rose-700 ring-rose-200"
    when "open", "in_progress", "medium"
      "bg-amber-50 text-amber-700 ring-amber-200"
    else
      "bg-slate-100 text-slate-600 ring-slate-200"
    end
  end

  def enum_label(value)
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
      "starter" => "Inicial",
      "growth" => "Crecimiento",
      "pro" => "Pro",
      "business" => "Empresa",
      "concise" => "Conciso",
      "warm" => "Cálido",
      "detailed" => "Detallado",
      "whatsapp" => "WhatsApp",
      "check_in" => "Check-in",
      "checkout" => "Checkout",
      "wifi" => "WiFi",
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
      "send_urgent_emails" => "Enviar emails urgentes"
    }

    translations.fetch(value.to_s, value.to_s.humanize)
  end

  def language_label(value)
    { "en" => "Inglés", "es" => "Español" }.fetch(value.to_s, "Español")
  end

  def language_options
    [["Español", "es"], ["Inglés", "en"]]
  end

  def card_class
    "rounded-xl border border-slate-200 bg-white shadow-sm"
  end

  def field_class
    "mt-2 w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-slate-400 focus:ring-4 focus:ring-slate-100"
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
