export type OperationalRisk =
  | "fire_or_smoke"
  | "gas"
  | "flood"
  | "intrusion"
  | "medical"
  | "electrical"
  | "unsafe_access"
  | "trapped"
  | "structural";

const RISK_PATTERNS: Array<[OperationalRisk, RegExp]> = [
  ["fire_or_smoke", /\b(fuego|incendio|incendiando|llamas?|humo|fire|flames?|smoke)\b/],
  ["gas", /\b(olor\s+a\s+gas|fuga\s+de\s+gas|gas\s+leak|smell\s+of\s+gas)\b/],
  ["flood", /\b(inundaci[oó]n|inundando|agua\s+por\s+todas\s+partes|p[eé]rdida\s+grave\s+de\s+agua|serious\s+(?:water\s+)?leak|flood(?:ing)?)\b/],
  ["intrusion", /\b(ladr[oó]n|intruso|intrusi[oó]n|entraron\s+a\s+robar|intento\s+de\s+ingreso|thief|intruder|break[\s-]?in)\b/],
  ["medical", /\b(lesi[oó]n|herid[oa]|emergencia\s+m[eé]dica|no\s+respira|desmayad[oa]|injur(?:y|ed)|medical\s+emergency|unconscious)\b/],
  ["electrical", /\b(cortocircuito|corto\s+el[eé]ctrico|chispas?|riesgo\s+el[eé]ctrico|electrical\s+(?:hazard|danger)|short\s+circuit|sparks?)\b/],
  ["unsafe_access", /\b(puerta\s+principal|puerta\s+de\s+entrada|front\s+door|main\s+door)\b.*\b(rota|rompi[oó]|no\s+cierra|insegura|broken|won't\s+lock|unsafe)\b/],
  ["trapped", /\b(encerrad[oa]|atrapad[oa]|no\s+puedo\s+salir|sin\s+posibilidad\s+de\s+salir|trapped|locked\s+in|cannot\s+(?:safely\s+)?exit)\b/],
  ["structural", /\b(peligro\s+estructural|techo\s+se\s+cae|pared\s+se\s+cae|derrumbe|structural\s+(?:danger|hazard)|ceiling\s+(?:is\s+)?collapsing)\b/],
];

export function operationalRiskFor(message: unknown): OperationalRisk | null {
  const normalized = normalize(String(message || ""));
  for (const [risk, pattern] of RISK_PATTERNS) {
    if (pattern.test(normalized)) return risk;
  }
  return null;
}

export function applyOperationalEmergencyGuardrail(decision: any, message: unknown) {
  const risk = operationalRiskFor(message);
  if (!risk || decision?.action !== "create_owner_task") return decision;

  return {
    ...decision,
    action: "create_alert",
    owner_task_kind: null,
    owner_task_id: null,
    alert_type: "emergency",
    escalation_required: true,
    escalation_reason: "emergency",
    escalation: {
      required: true,
      category: "emergency",
      reason_code: "emergency",
      urgency: "urgent",
      summary_for_host: decision?.task_summary || decision?.intent_summary || String(message || ""),
    },
    audit: {
      ...(decision?.audit || {}),
      operational_emergency_guardrail: {
        applied: true,
        risk,
        previous_action: decision?.action,
      },
    },
  };
}

function normalize(value: string) {
  return value.toLowerCase().normalize("NFD").replace(/\p{Diacritic}/gu, "").replace(/\s+/g, " ").trim();
}
