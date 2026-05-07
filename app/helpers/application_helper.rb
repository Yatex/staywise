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
